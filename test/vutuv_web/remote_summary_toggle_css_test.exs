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
  @js Path.expand("../../assets/js/app.js", __DIR__)
  @markup Path.expand("../../lib/vutuv_web/live/fediverse_account_live.ex", __DIR__)

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

    assert js =~ "[data-post-preview], [data-remote-summary]",
           "the sweep has to reach the account description, not only the post previews"
  end

  test "the toggle wrapper declares no display of its own" do
    markup = File.read!(@markup)

    assert markup =~ "data-remote-summary-toggle",
           "the two labels need one wrapper whose display the CSS can own"

    refute markup =~ ~r/data-remote-summary-toggle[^>\n]*class=/,
           "a display utility beside the state rule is the issue #880 trap: whichever CSS " <>
             "is emitted last wins, silently"
  end
end
