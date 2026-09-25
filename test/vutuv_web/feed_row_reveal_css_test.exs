defmodule VutuvWeb.FeedRowRevealCssTest do
  use ExUnit.Case, async: true

  # A feed row revealed through the "N new posts" pill slides in with
  # `feed-row-reveal`. The animation must leave nothing behind once it has run.
  #
  # Why: with `both` (or `forwards`) the last keyframe stays applied for good,
  # and a leftover `transform: translateY(0)` is still a transform, so every
  # revealed row became a stacking context of its own. The ⋯ menu's `z-20`
  # then only counted inside its own row, and the next row painted over the
  # open menu: its text, its link screenshot, all on top of "Report" and the
  # hide list (reported 2026-09-24 on /feed). A static source check in the
  # spirit of `dark_mode_css_test.exs`.

  @app_css Path.expand("../../assets/css/app.css", __DIR__)

  test "the reveal keeps no end state that would trap the row's menus" do
    css = File.read!(@app_css)

    [animation] = Regex.run(~r/animation:\s*feed-row-reveal[^;]*;/, css)
    refute animation =~ ~r/\b(both|forwards)\b/, "found: #{animation}"
  end
end
