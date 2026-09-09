defmodule Vutuv.Profiles.LinkBadgesTest do
  @moduledoc """
  The catalog a member links their own homepage from, and the badge files it
  hands out.

  The verification half — that every HTML snippet carries the exact `rel="me"`
  back-link `Vutuv.Profiles.LinkVerification` goes looking for — is asserted in
  `company_controller_test.exs`, where it reads them back through the real
  parser. What is here is the half a rendering test cannot see: that the three
  badge files still draw the brand, at the shape their snippets claim.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Profiles.LinkBadges

  @brand "priv/static/images/brand"

  # Every `d=` of an SVG, in document order, whitespace flattened — the brand
  # files break their paths across lines and the badges do not, so comparing
  # them verbatim would fail on formatting alone. `[^>]*` because the mark
  # carries a `fill=` before its `d=` and the wordmark does not.
  defp paths(file) do
    @brand
    |> Path.join(file)
    |> File.read!()
    |> then(&Regex.scan(~r/<path[^>]*\sd="([^"]*)"/, &1, capture: :all_but_first))
    |> List.flatten()
    |> Enum.map(&(&1 |> String.replace(~r/\s+/, " ") |> String.trim()))
  end

  describe "the badge files" do
    # A standalone SVG cannot `<use>` a shape from another file, so each badge
    # inlines the wordmark's five letters and the mark's "v". That copy is
    # forced; what is not forced is that nothing notices when the brand is
    # redrawn and the badges keep the old shapes. This is that notice.
    #
    # Which files spell "vutuv" across themselves is the catalog's own
    # `wordmark?`, not a guess from the shape: "wider than it is tall" holds for
    # today's badges by layout accident, and a stacked badge would drop out of
    # this check without a word.
    test "still draw the same wordmark the brand asset does" do
      wordmark = paths("vutuv-wordmark.svg")
      assert length(wordmark) == 5

      spelled = Enum.filter(LinkBadges.badges(), & &1.wordmark?)
      assert spelled != []

      for badge <- spelled do
        file = Path.basename(badge.path)

        assert file |> paths() |> Enum.take(-5) == wordmark,
               "#{file} no longer carries the wordmark from vutuv-wordmark.svg — " <>
                 "rebuild it from the brand files rather than editing it by hand"
      end
    end

    test "still draw the same v the icon mark does" do
      [v] = paths("vutuv-mark.svg")

      for badge <- LinkBadges.badges() do
        file = Path.basename(badge.path)
        assert hd(paths(file)) == v, "#{file} no longer carries the mark's own glyph"
      end
    end

    # The badge's own `width`/`height` are what the snippets write into their
    # `<img>`, so a file whose shape stops matching them is handed out stretched
    # on somebody else's page. The **ratio** is what has to agree, not the
    # numbers: a badge is drawn 1:1 with its box while the square icon is a 512
    # px artboard shown at 40.
    test "are drawn at the shape the snippets claim" do
      for badge <- LinkBadges.badges() do
        svg = File.read!(Path.join(@brand, Path.basename(badge.path)))

        assert [w, h] = Regex.run(~r/viewBox="0 0 (\d+) (\d+)"/, svg, capture: :all_but_first),
               "#{badge.path} has no plain `viewBox=\"0 0 w h\"` to read its shape from"

        # Cross-multiplied, so the comparison is exact and needs no tolerance.
        assert String.to_integer(w) * badge.height == String.to_integer(h) * badge.width,
               "#{badge.path} is drawn #{w}x#{h}, which the <img> at " <>
                 "#{badge.width}x#{badge.height} would stretch"
      end
    end
  end

  describe "snippets/1" do
    test "hand out both the finished snippet and the template the handle field rewrites" do
      snippet = LinkBadges.snippets("ada") |> Enum.find(&(&1.key == "text"))

      assert snippet.code =~ "/ada"
      refute snippet.code =~ "__HANDLE__"
      assert snippet.template =~ "__HANDLE__"
      assert LinkBadges.fill(snippet.template, "ada") == snippet.code
    end

    test "default to the placeholder, so nothing renders a stranger's handle" do
      for snippet <- LinkBadges.snippets() do
        assert snippet.code =~ LinkBadges.handle_placeholder()
      end
    end
  end
end
