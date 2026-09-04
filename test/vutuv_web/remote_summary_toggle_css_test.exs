defmodule VutuvWeb.RemoteSummaryToggleCssTest do
  use ExUnit.Case, async: true

  # The fediverse account description hides its own expand toggle when there is
  # nothing behind it (issue #1268), and the whole thing hangs on one CSS gate
  # being written the awkward way round.
  #
  # `.is-measured:not(.is-clamped)` reads like a longer way of saying
  # `:not(.is-clamped)`, and it is not. The class only ever arrives from
  # JavaScript, so an element that nothing measured — a reader with JavaScript
  # off, or a page in the moment before the sweep runs — carries neither class.
  # Gating on `:not(.is-clamped)` alone would read that state as "nothing is
  # cut" and hide the toggle, leaving a long description permanently truncated
  # with no way to open it. The enhancement has to be able to take away a
  # useless control and nothing else.
  #
  # A static source check in the spirit of `line_clamp_css_test.exs` and
  # `dark_mode_css_test.exs`: it cannot measure a browser, but it holds the
  # shape that makes the browser's answer safe.

  @css Path.expand("../../assets/css/components.css", __DIR__)
  # The measuring and the sweep that drives it live apart: `revealPreviewClamp`
  # is in util.js, where the mention card can import it (its fragment is swapped
  # into a body-level panel, so nothing sweeps it), and app.js keeps the page
  # lifecycle that calls the sweep.
  @js Path.expand("../../assets/js/util.js", __DIR__)
  @sweep Path.expand("../../assets/js/app.js", __DIR__)
  # Every wearer of the arrangement. A second one joined in the mention card,
  # and the trap this test holds is per element, not per page.
  @markup [
    Path.expand("../../lib/vutuv_web/live/fediverse_account_live.ex", __DIR__),
    Path.expand("../../lib/vutuv_web/templates/remote_actor_card/card.html.heex", __DIR__)
  ]

  test "the toggle is hidden only once something has actually measured it" do
    css = File.read!(@css)

    assert css =~
             "[data-remote-summary].is-measured:not(.is-clamped) [data-remote-summary-toggle]",
           "the toggle's hide rule must require `is-measured`, or a page with no JavaScript " <>
             "loses the way to open a long description"

    refute css =~ ~r/\[data-remote-summary\]:not\(\.is-clamped\)/,
           "gating on `:not(.is-clamped)` alone reads 'never measured' as 'nothing is cut'"
  end

  test "the measurement stamps is-measured, and refuses to answer for an unpainted body" do
    js = File.read!(@js)

    assert js =~ ~s|classList.add("is-measured")|,
           "revealPreviewClamp must record that it looked, not only what it found"

    assert js =~ "body.clientHeight === 0",
           "an open <details> hides the clamped copy, so both heights read 0 — measuring " <>
             "that would answer 'uncut' and hide the Show less the reader needs"

    assert File.read!(@sweep) =~ "[data-post-preview], [data-remote-summary]",
           "the sweep has to reach the account description, not only the post previews"
  end

  test "no wearer's toggle wrapper declares a display of its own" do
    for path <- @markup do
      markup = File.read!(path)

      assert markup =~ "data-remote-summary-toggle",
             "#{path}: the two labels need one wrapper whose display the CSS can own"

      refute markup =~ ~r/data-remote-summary-toggle[^>]*class=/,
             "#{path}: a display utility beside the state rule is the issue #880 trap: " <>
               "whichever CSS is emitted last wins, silently. Put the utilities on the " <>
               "labels inside instead."
    end
  end
end
