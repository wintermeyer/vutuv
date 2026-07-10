defmodule VutuvWeb.PostComponentsTest do
  use ExUnit.Case, async: true

  alias Vutuv.Accounts.User
  alias VutuvWeb.PostComponents

  describe "post_body_style/1" do
    test "returns nil for the default preferences so the DOM stays clean" do
      # A logged-out reader and a fresh account both get the defaults, which the
      # CSS fallbacks already cover — so no inline style override is emitted.
      assert PostComponents.post_body_style(User.post_prefs(nil)) == nil
      assert PostComponents.post_body_style(User.post_prefs(%User{})) == nil
    end

    test "emits the CSS custom properties for a custom preference" do
      prefs =
        User.post_prefs(%User{
          post_lines_desktop: 4,
          post_lines_mobile: 12,
          post_hyphenate_desktop: true,
          post_hyphenate_mobile: false
        })

      style = PostComponents.post_body_style(prefs)

      assert style =~ "--post-clamp-desktop:4"
      assert style =~ "--post-clamp-mobile:12"
      assert style =~ "--post-hyphens-desktop:auto"
      assert style =~ "--post-hyphens-mobile:manual"
    end

    test "maps a 0 line count to the `none` keyword so that breakpoint unclamps" do
      prefs = User.post_prefs(%User{post_lines_desktop: 0, post_lines_mobile: 8})
      style = PostComponents.post_body_style(prefs)

      assert style =~ "--post-clamp-desktop:none"
      assert style =~ "--post-clamp-mobile:8"
    end
  end
end
