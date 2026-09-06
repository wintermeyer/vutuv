defmodule VutuvWeb.LightboxZoomTest do
  use ExUnit.Case, async: true

  # The lightbox's tap-to-zoom (a fitted picture toggled to 1:1, panned by
  # scrolling). Three things have to hold for that to be more than a class
  # flip, none visible in the markup, so this reads the two source files the
  # way `hover_reveal_css_test` reads its rule.

  @js Path.expand("../../assets/js/lightbox.js", __DIR__)
  @css Path.expand("../../assets/css/components.css", __DIR__)

  defp js, do: File.read!(@js)

  defp css_block do
    css = File.read!(@css)
    [_, rest] = String.split(css, ".lightbox.is-zoomed", parts: 2)
    [body, _] = String.split(rest, "\n/*", parts: 2)
    ".lightbox.is-zoomed" <> body
  end

  test "a tap on the picture toggles the zoom, and stepping to another photo drops it" do
    assert js() =~ ~r/classList\.remove\("is-zoomed"/,
           "show() has to start every photo fitted, or a zoomed capture is followed by a zoomed neighbour"
  end

  test "the swipe that steps a gallery yields while the picture is zoomed" do
    # A zoomed picture is panned by dragging, and a horizontal drag is exactly
    # the gesture the gallery reads as "next photo".
    [_, touchend] = String.split(js(), ~s("touchend"), parts: 2)
    assert touchend =~ "is-zoomed"
  end

  test "zoomed, the stage scrolls and the picture leaves the fit behind" do
    block = css_block()

    assert block =~ "overflow: auto", "the pan is a scroll, so a finger and a trackpad both do it"
    assert block =~ "max-width: none"
    assert block =~ "max-height: none"
    assert block =~ "align-items: flex-start", "centred, the left half could never be scrolled to"
  end
end
