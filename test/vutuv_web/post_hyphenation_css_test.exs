defmodule VutuvWeb.PostHyphenationCssTest do
  use ExUnit.Case, async: true

  # Post bodies hyphenate on mobile so long German compound words
  # (Digitalisierung, unternehmenseigene) wrap cleanly in the narrow phone
  # column instead of leaving ragged gaps or a hard mid-word break. A static
  # source check in the spirit of `dark_mode_css_test.exs`: read the stylesheet
  # and assert the rule exists, scoped to a mobile max-width media query, with
  # the `-webkit-` prefix iOS/Safari (the main mobile target) still needs.

  @components_css Path.expand("../../assets/css/components.css", __DIR__)

  defp components_css, do: File.read!(@components_css)

  test "post bodies hyphenate inside a mobile max-width media query" do
    assert components_css() =~
             ~r/@media\s*\(width\s*<\s*[\d.]+rem\)\s*\{[^@]*?\.markdown--post\b[^{}]*\{[^}]*hyphens:\s*auto/s,
           "components.css must enable `hyphens: auto` on `.markdown--post` " <>
             "inside a mobile max-width media query (so posts hyphenate on phones)"
  end

  test "the post-body hyphenation carries the -webkit- prefix for iOS/Safari" do
    assert components_css() =~ ~r/\.markdown--post\b[^{}]*\{[^}]*-webkit-hyphens:\s*auto/s,
           "the post-body hyphenation rule needs `-webkit-hyphens: auto`; " <>
             "without it iOS/Safari (the main mobile target) does not hyphenate"
  end
end
