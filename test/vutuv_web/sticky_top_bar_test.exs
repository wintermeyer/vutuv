defmodule VutuvWeb.StickyTopBarTest do
  use VutuvWeb.ConnCase, async: true

  # The top bar carries `sticky top-0` and still scrolled away with the page
  # (issue #1727). A sticky element only slides inside its own parent's box, and
  # both wrappers between the bar and `<body>` — the `live_render` container and
  # `#app-shell` — were exactly as tall as the bar, so there were zero pixels to
  # slide in. `display: contents` drops those boxes without touching the nodes.
  # The full reasoning and the measurements live on `ShellLive` itself.
  #
  # Why this test exists at all: the failure is invisible. `sticky top-0` stays
  # in the markup and reads as if it works, the page looks right until somebody
  # scrolls, and no test the repo had would have gone red. The next person to
  # put a box back between the bar and the body — a wrapper `<div>` around the
  # embedding, a `class=` on the container that is not `contents`, a stray
  # `display: block` — needs something that fails.
  #
  # So this asserts the RENDERED markup rather than the source: `container:` is
  # a `use` option whose effect only exists once Phoenix has built the wrapper,
  # and a source grep would pass on an option that some later refactor stopped
  # applying. Both wrappers are checked, because removing the box from only one
  # of them still leaves the bar trapped in the other.
  #
  # Calibration (do this by patch, and put it back): drop `container:` from
  # `ShellLive` and the first assertion goes red; drop `class="contents"` from
  # `#app-shell` in `render/1` and the second does.
  #
  # Both embeddings are covered because the layout has two of them — `@conn` for
  # a dead render, `@socket` with `sticky: true` inside a `live_session` — and
  # the fix has to hold for both. It does so by construction now that the option
  # sits on the LiveView instead of at each call site, which is exactly the
  # property worth pinning down.

  defp shell_wrappers(conn, path) do
    html = conn |> get(path) |> html_response(200)

    assert [_, container] = Regex.run(~r/(<div[^>]*>)\s*<div id="app-shell"/s, html),
           "no `#app-shell` in the page at #{path}, so the shell did not render"

    assert [_, shell] = Regex.run(~r/(<div id="app-shell"[^>]*>)/, html)

    {container, shell}
  end

  describe "the shell generates no box between the top bar and <body>" do
    test "on a dead render embedded with @conn", %{conn: conn} do
      {container, shell} = shell_wrappers(conn, "/")

      assert container =~ ~r/class="[^"]*\bcontents\b/,
             """
             The `live_render` wrapper around ShellLive is a box again, so the
             top bar's `sticky top-0` has a 65px-tall parent to stick to and
             scrolls away with the page (issue #1727). Restore
             `container: {:div, class: "contents"}` on ShellLive.

             Got: #{container}
             """

      assert shell =~ ~r/class="[^"]*\bcontents\b/,
             """
             `#app-shell` is a box again. Dropping only the outer wrapper's box
             leaves the bar trapped in this one — both have to go
             (issue #1727).

             Got: #{shell}
             """
    end

    test "on a live_session page embedded with @socket", %{conn: conn} do
      {container, shell} = shell_wrappers(conn, "/search")

      assert container =~ ~r/class="[^"]*\bcontents\b/
      assert shell =~ ~r/class="[^"]*\bcontents\b/
    end
  end
end
