defmodule VutuvWeb.PressCardClassAvailabilityTest do
  @moduledoc """
  The Press card is drawn into a document that may be hours old.

  The profile is a LiveView, and a tab left open across a deploy reloads
  nothing: the socket reconnects to the new release and the card's markup is
  patched into a page still holding the **previous** release's stylesheet. So a
  class only this card uses is a class that document cannot draw.

  `VutuvWeb.ClassAvailability` runs the check and explains the method; what is
  here is the two places the press markup lives and how it spells its classes.
  It covers the section page's markup as well — that page is a dead render and
  could not be caught out this way, but one bound over the whole module means
  nobody has to work out which half of it is safe.
  """
  use ExUnit.Case, async: true

  alias VutuvWeb.ClassAvailability

  @components "lib/vutuv_web/components/press_kit_components.ex"
  @profile "lib/vutuv_web/templates/user/show.html.heex"

  test "every class the press surfaces draw with also ships elsewhere in the tree" do
    own = [File.read!(@components), card_markup()]

    # A vacuous run is this guard's own failure mode: an extractor that reads
    # none of the markup vouches for nothing while passing. The card and the two
    # section entries carry far more than this between them.
    assert length(Enum.flat_map(own, &classes/1)) > 40,
           "too few classes were read out of the press markup — `classes/1` has " <>
             "stopped seeing it, so this test proves nothing"

    orphans = ClassAvailability.orphans(own, &classes/1)

    assert orphans == [],
           "These classes appear only in the press surfaces, so the previous\n" <>
             "release's stylesheet has no rule for them and a profile tab open across\n" <>
             "a deploy draws the Press card unstyled. Pick a class the tree already\n" <>
             "uses bare:\n" <> Enum.join(orphans, "\n")
  end

  # The `<.card :if={press_any?…}>` block of the profile template, from its
  # opening tag to its close. It says so rather than raising a `MatchError` on
  # nil: renaming that card is the likeliest way to break this guard, and "no
  # match of right hand side value: nil" names neither.
  defp card_markup do
    case Regex.run(~r/(<\.card :if=\{press_any\?.*?<\/\.card>)/s, File.read!(@profile)) do
      [_, markup] -> markup
      nil -> flunk("no `<.card :if={press_any?…}>` block in #{@profile}")
    end
  end

  # Both spellings this codebase uses: the literal attribute and the list form.
  # Reading only the first would hand back fewer classes on a file that mostly
  # uses the second — which is the vacuous pass the assertion above catches.
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
