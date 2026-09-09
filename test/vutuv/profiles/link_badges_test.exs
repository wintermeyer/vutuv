defmodule Vutuv.Profiles.LinkBadgesTest do
  @moduledoc """
  The catalog a member links their own homepage from, and the two badge files it
  hands out.

  The verification half — that every HTML snippet carries the exact `rel="me"`
  back-link `Vutuv.Profiles.LinkVerification` goes looking for — is asserted in
  `company_controller_test.exs`, where it reads them back through the real
  parser. What is here is the half a rendering test cannot see: that the badge
  files still draw the brand.
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
    test "still draw the same wordmark the brand asset does" do
      wordmark = paths("vutuv-wordmark.svg")
      assert length(wordmark) == 5

      for badge <- LinkBadges.badges() do
        file = Path.basename(badge.path)

        assert badge.path |> Path.basename() |> paths() |> Enum.take(-5) == wordmark,
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
    # `<img>`, so a file redrawn at another size would hand out an `<img>` that
    # stretches it on somebody else's page.
    test "are drawn at the size the snippets claim" do
      for badge <- LinkBadges.badges() do
        svg = File.read!(Path.join(@brand, Path.basename(badge.path)))

        assert svg =~ ~s|viewBox="0 0 #{badge.width} #{badge.height}"|,
               "#{badge.path} is not #{badge.width}x#{badge.height}, which its snippets claim"
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
