defmodule VutuvWeb.PersonalNotesClassAvailabilityTest do
  @moduledoc """
  The personal-notes timeline is drawn into documents that may be hours old.

  The panel sits in the profile LiveView and the overview streams its rows, so a
  tab left open across a deploy gets the new markup patched into a page still
  holding the previous release's stylesheet. A class only these rows use is a
  class that document cannot draw: the timeline grid once relied on two
  arbitrary `grid-cols-[…]` values, and an old stylesheet would have stacked the
  date, the rail, the text and the menu on top of each other.

  `VutuvWeb.ClassAvailability` runs the check and explains the method.
  """
  use ExUnit.Case, async: true

  alias VutuvWeb.ClassAvailability

  @components "lib/vutuv_web/components/personal_note_components.ex"

  # The rail's named-group variants: they tint the newest dot and end the line
  # under the last note. Nothing else in the tree has a named group, and an old
  # stylesheet without them draws a grey first dot and a short tail under the
  # last note, which reads fine. So they are allowed by name, and only they.
  @rail_only ~w(
    group/note
    group-first/note:bg-brand-600
    group-first/note:ring-4
    group-first/note:ring-brand-100
    group-last/note:hidden
    group-last/note:pb-0
    dark:group-first/note:bg-brand-400
    dark:group-first/note:ring-brand-800/60
  )

  test "every class the notes timeline draws with also ships elsewhere in the tree" do
    own = [File.read!(@components)]

    assert length(Enum.flat_map(own, &classes/1)) > 40,
           "too few classes were read out of the notes markup — `classes/1` has " <>
             "stopped seeing it, so this test proves nothing"

    orphans = ClassAvailability.orphans(own, &classes/1) -- @rail_only

    assert orphans == [],
           "These classes appear only in the notes markup, so the previous\n" <>
             "release's stylesheet has no rule for them and a tab open across a\n" <>
             "deploy draws the timeline broken. Pick a class the tree already uses:\n" <>
             Enum.join(orphans, "\n")
  end

  test "the rail exemptions are still in use" do
    markup = File.read!(@components)

    for class <- @rail_only do
      assert markup =~ class, "#{class} is exempt but no longer used; drop it from @rail_only"
    end
  end

  # Both spellings this codebase uses: the literal attribute and the list form.
  defp classes(markup) do
    literal = Regex.scan(~r/class="([^"]+)"/, markup)

    lists =
      ~r/class=\{\[(.*?)\]\}/s
      |> Regex.scan(markup)
      |> Enum.flat_map(fn [_, body] -> Regex.scan(~r/"([^"]*)"/, body) end)

    (literal ++ lists)
    |> Enum.flat_map(fn [_, list] -> String.split(list) end)
    |> Enum.uniq()
  end
end
