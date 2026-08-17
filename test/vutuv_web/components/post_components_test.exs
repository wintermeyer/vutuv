defmodule VutuvWeb.PostComponentsTest do
  use ExUnit.Case, async: true

  alias Vutuv.Accounts.User
  alias VutuvWeb.PostComponents

  # Render the tab bar on its own. A function component needs `__changed__`
  # in its assigns; `rendered_to_string/1` then gives the markup every one of
  # its three call sites emits.
  defp tabs_html(opts \\ []) do
    assigns =
      opts
      |> Enum.into(%{active: "all", event: "filter", options: nil, rest: %{}})
      |> Map.put(:__changed__, nil)

    Phoenix.LiveViewTest.rendered_to_string(PostComponents.post_filter_tabs(assigns))
  end

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

  describe "post_filter_tabs/1 reads on every page background" do
    # The bar renders on BOTH of this app's backgrounds — inside a white card
    # (the profile's Beiträge section) and directly on the `slate-100` page
    # canvas (the feed, the `/:slug/posts` archive). It used to sit on a
    # `bg-slate-100` track, which is the canvas colour exactly, so on two of
    # those three surfaces the control was invisible and only the feed's lone
    # white pill showed. These tests pin the two properties that fix it, since
    # nothing else fails when a colour quietly matches its background.
    #
    # The three surfaces are checked as one because they are one component:
    # whatever these assert is what all of them render.

    test "the container paints no track, so no page background can swallow it" do
      html = tabs_html()
      [container | _] = String.split(html, ">", parts: 2)

      refute container =~ "bg-slate",
             "the tab bar must not paint a filled track: `bg-slate-100` IS the page canvas"
    end

    test "the active tab is tinted apart from white AND from the slate canvas" do
      html = tabs_html(active: "reposts")

      # brand-100 (#dbeafe) reads against white and against slate-100.
      # brand-50 (#eff6ff) does not — it differs from the canvas by ~6 in one
      # channel, which is why the shell's nav pill recipe cannot be copied here
      # verbatim (its header is white).
      assert html =~ "bg-brand-100"
      refute html =~ "bg-brand-50 "

      # The tint marks the ACTIVE tab, and only it.
      assert html |> String.split("bg-brand-100") |> length() == 2
    end

    test "an inactive tab's hover is not the canvas colour either" do
      html = tabs_html()

      assert html =~ "hover:bg-slate-200"
      refute html =~ "hover:bg-slate-100"
    end

    test "every tab clears the 40px mobile tap target" do
      # text-sm is a 20px line box, so py-2.5 (10px each side) is exactly 40.
      html = tabs_html()

      assert html =~ "py-2.5"
      refute html =~ "py-1 "
    end
  end

  describe "post_filter_tabs/1 unseen dots (issue #1503)" do
    # How many tabs the given markup dots.
    defp dots(html), do: length(String.split(html, "data-post-filter-unseen")) - 1

    test "no dots at all unless a caller asks for them" do
      # The profile and the `/:slug/posts` archive pass no `unseen`, and their
      # tabs must look exactly as they did.
      assert dots(tabs_html()) == 0
    end

    test "an inactive tab named in unseen wears the coral dot" do
      html = tabs_html(active: "all", unseen: ["reposts"])

      assert dots(html) == 1
      assert html =~ "bg-accent"
      # Icon-free and count-free, so the word is the whole accessible name.
      assert html =~ "sr-only"
    end

    test "the active tab never dots, whatever it is passed" do
      # You are looking at it — the feed's own bookkeeping should never send
      # this, and the control must not be able to contradict itself if it does.
      html = tabs_html(active: "reposts", unseen: ["all", "reposts"])

      assert dots(html) == 1
    end
  end
end
