defmodule VutuvWeb.LoginInputVisibilityTest do
  use ExUnit.Case, async: true

  # Regression test for issue #761 ("Login email address is invisible").
  #
  # Tailwind v4's Preflight base reset gives every form control
  # `color: inherit` and `background-color: transparent`. On the login,
  # PIN and registration screens the inputs carry the `.imagebox__input`
  # class inside `.imagebox__form`, which sets `color: #fff`. The inputs
  # therefore inherited white text and a transparent field, rendering the
  # typed value as white-on-photo — invisible in Chrome and Firefox.
  #
  # The fix is a CSS override that gives those inputs a solid field and a
  # dark text colour. This test reads the source stylesheet and asserts the
  # override is present and effective, so the regression cannot creep back
  # in unnoticed.

  @app_css Path.expand("../../assets/css/app.css", __DIR__)

  defp imagebox_input_rule do
    css = File.read!(@app_css)

    # Grab the declaration block of the rule that targets `.imagebox__input`
    # while excluding submit buttons (which legitimately stay blue/white).
    [_, declarations] =
      Regex.run(~r/\.imagebox__input[^{}]*:not\(\[type=["']?submit["']?\]\)[^{}]*\{([^}]*)\}/, css) ||
        flunk("""
        No `.imagebox__input:not([type=submit])` rule found in #{@app_css}.
        The login/registration inputs need an explicit, visible fill so they
        don't inherit Tailwind Preflight's transparent/white reset (issue #761).
        """)

    declarations
  end

  test "the source app.css exists" do
    assert File.exists?(@app_css)
  end

  test "imagebox inputs are given a concrete, non-transparent background" do
    declarations = imagebox_input_rule()

    assert declarations =~ ~r/background-color\s*:/,
           "the input rule must set a background-color"

    refute declarations =~ ~r/background-color\s*:\s*(transparent|#0000\b|rgba\(\s*0\s*,\s*0\s*,\s*0\s*,\s*0\s*\))/i,
           "the input background must not be transparent (it would show the photo through it)"
  end

  test "imagebox inputs are given a concrete, non-inherited text colour" do
    declarations = imagebox_input_rule()

    assert declarations =~ ~r/(^|;)\s*color\s*:/,
           "the input rule must set an explicit text color"

    refute declarations =~ ~r/(^|;)\s*color\s*:\s*inherit/i,
           "the input text color must not inherit the white `.imagebox__form` color"
  end
end
