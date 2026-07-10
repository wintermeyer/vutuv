defmodule VutuvWeb.PostHyphenationCssTest do
  use ExUnit.Case, async: true

  # Post-body hyphenation is now a per-reader, per-breakpoint preference
  # (Vutuv.Accounts.User.post_prefs/1 → the `--post-hyphens-*` CSS custom
  # properties the post body sets inline). What still must hold in the
  # stylesheet is the DEFAULT for a reader who set nothing: no hyphenation on
  # desktop, browser hyphenation on the narrow phone column — expressed as the
  # CSS-var fallbacks, so long German compound words (Digitalisierung) still
  # wrap cleanly on phones by default. A static source check in the spirit of
  # `dark_mode_css_test.exs`: read the stylesheet and assert the fallback rule
  # exists, scoped to a mobile max-width media query, with the `-webkit-` prefix
  # iOS/Safari (the main mobile target) still needs.

  @components_css Path.expand("../../assets/css/components.css", __DIR__)

  defp components_css, do: File.read!(@components_css)

  test "post bodies hyphenate on mobile by default inside a max-width media query" do
    assert components_css() =~
             ~r/@media\s*\(width\s*<\s*[\d.]+rem\)\s*\{[^@]*?\.markdown--post\b[^{}]*\{[^}]*hyphens:\s*var\(--post-hyphens-mobile,\s*auto\)/s,
           "components.css must default `.markdown--post` to `hyphens: " <>
             "var(--post-hyphens-mobile, auto)` inside a mobile max-width media " <>
             "query (so posts hyphenate on phones unless the reader turns it off)"
  end

  test "the post-body hyphenation carries the -webkit- prefix for iOS/Safari" do
    assert components_css() =~
             ~r/\.markdown--post\b[^{}]*\{[^}]*-webkit-hyphens:\s*var\(--post-hyphens-mobile,\s*auto\)/s,
           "the mobile hyphenation rule needs `-webkit-hyphens: " <>
             "var(--post-hyphens-mobile, auto)`; without the prefix iOS/Safari " <>
             "(the main mobile target) does not hyphenate"
  end
end
