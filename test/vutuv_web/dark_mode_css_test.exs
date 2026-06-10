defmodule VutuvWeb.DarkModeCssTest do
  use ExUnit.Case, async: true

  # Regression test for the broken system dark mode.
  #
  # Dark mode follows `prefers-color-scheme` (no toggle). The legacy
  # stylesheet ships light-only element rules that the Direction A reskin in
  # `components.css` must override, and the dark-mode block there must win
  # the specificity battles against legacy. Three bugs shipped this way:
  #
  #   * `body { background: #eee; color: #333 }` in legacy.css had no dark
  #     counterpart, so every page kept a light grey canvas behind dark
  #     cards, and page titles (`.profile-header__info h1`, near-white in
  #     dark) were invisible on it.
  #   * legacy's `.card-list .card { background: #fff }` (0,2,0) beat the
  #     dark `.card { background: #0f172a }` (0,1,0), so all legacy cards
  #     stayed white while their text switched to light dark-mode colours.
  #   * legacy paints bare `<header>`/`<footer>` as white bars of the old
  #     chrome; the new shell and layout style them with utilities, so the
  #     Messages thread header and the page footer rendered as white strips
  #     in dark mode.
  #
  # These are static source checks in the spirit of
  # `login_input_visibility_test.exs`: they read the stylesheet and assert
  # the dark-mode rules exist with the selectors that win.

  @components_css Path.expand("../../assets/css/components.css", __DIR__)
  @app_css Path.expand("../../assets/css/app.css", __DIR__)
  @root_layout Path.expand(
                 "../../lib/vutuv_web/templates/layout/root.html.heex",
                 __DIR__
               )

  # Comments mention selectors by name; strip them so `rule/2` only ever
  # matches real rules.
  defp components_css do
    Regex.replace(~r{/\*.*?\*/}s, File.read!(@components_css), "")
  end

  defp dark_block do
    case String.split(components_css(), ~r/@media\s*\(prefers-color-scheme:\s*dark\)/, parts: 2) do
      [_, block] ->
        block

      _ ->
        flunk("""
        No `@media (prefers-color-scheme: dark)` block found in
        #{@components_css}. Dark mode must follow the system setting.
        """)
    end
  end

  defp rule(css, selector_re) do
    case Regex.run(~r/#{selector_re}[^{}]*\{([^}]*)\}/, css) do
      [_, declarations] -> declarations
      _ -> nil
    end
  end

  test "dark mode recolors the page canvas (body) that legacy paints light grey" do
    declarations =
      rule(dark_block(), ~r/(?:^|[,}\s])body/.source) ||
        flunk("the dark block must restyle `body` (legacy sets `#eee`/`#333`)")

    assert declarations =~ ~r/background\s*:/,
           "the dark body rule must set a dark canvas background"

    assert declarations =~ ~r/(?:^|;)\s*color\s*:/,
           "the dark body rule must set a light base text colour"
  end

  test "dark card background also targets .card-list .card (legacy specificity)" do
    # legacy's `.card-list .card { background:#fff }` (0,2,0) outranks a bare
    # `.card` (0,1,0) dark override, so the dark rule needs the same selector.
    declarations =
      rule(dark_block(), ~r/\.card-list\s+\.card/.source) ||
        flunk("""
        The dark block must include a `.card-list .card` selector for the
        card background; a bare `.card` loses to legacy's
        `.card-list .card { background: #fff }`.
        """)

    assert declarations =~ ~r/background\s*:/
  end

  test "dark mode restyles the secondary/cancel button hover" do
    # The light `.button--cancel:hover { background: #e2e8f0 }` rule (0,2,0)
    # outranks the dark `.button--cancel { background: #1e293b }` base (0,1,0),
    # so without a dark hover rule the button flashes light grey on hover.
    declarations =
      rule(dark_block(), ~r/\.button--cancel:hover/.source) ||
        flunk("""
        The dark block must restyle `.button--cancel:hover` (and
        `.button--secondary:hover`); the light hover rule outranks the dark
        base rule and flashes the button light grey on hover.
        """)

    assert declarations =~ ~r/background\s*:/

    assert rule(dark_block(), ~r/\.button--secondary:hover/.source),
           "the dark block must also cover `.button--secondary:hover`"
  end

  test "the legacy .select wrapper keeps no white-filled arrow background" do
    # The legacy `<div class="select">` wrapper painted a white square +
    # arrow data-URI behind the native select; in dark mode the white square
    # peeked out behind the select's rounded corners. The native select
    # renders its own arrow, so the rule stays deleted.
    refute components_css() =~ ~r/\.select\s*\{[^}]*fill%3D%27%23FFF/,
           "components.css must not paint the .select wrapper with the " <>
             "white-filled data-URI arrow (white box in dark mode)"
  end

  test "the legacy stylesheet stays deleted" do
    # legacy.css was removed after its still-used rules were folded into
    # components.css. It painted bare <header>/<footer> as white bars and
    # hardcoded a light-only canvas; nothing may re-import it.
    legacy = Path.expand("../../assets/css/legacy.css", __DIR__)
    refute File.exists?(legacy), "assets/css/legacy.css must not come back"

    refute File.read!(@app_css) =~ ~r/@import\s+"[^"]*legacy/,
           "app.css must not import legacy.css"
  end

  test "the browser is told both color schemes are supported" do
    app_css = File.read!(@app_css)

    assert app_css =~ ~r/color-scheme\s*:\s*light\s+dark/,
           "app.css must declare `color-scheme: light dark` so native form " <>
             "controls and scrollbars follow the system scheme"
  end

  test "root layout declares a theme-color for both color schemes" do
    layout = File.read!(@root_layout)

    assert layout =~ ~r/theme-color[^>]*prefers-color-scheme:\s*light/s ||
             layout =~ ~r/prefers-color-scheme:\s*light[^>]*theme-color/s,
           "root layout needs a light theme-color meta"

    assert layout =~ ~r/theme-color[^>]*prefers-color-scheme:\s*dark/s ||
             layout =~ ~r/prefers-color-scheme:\s*dark[^>]*theme-color/s,
           "root layout needs a dark theme-color meta"
  end
end
