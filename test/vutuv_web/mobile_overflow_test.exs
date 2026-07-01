defmodule VutuvWeb.MobileOverflowTest do
  use ExUnit.Case, async: true

  # Regression test for horizontal overflow on phones (the app is meant to be
  # 100% mobile first).
  #
  # The content+rail pages use `grid gap-6 md:grid-cols-3` with the main column
  # spanning `md:col-span-2`. Tailwind's `md:grid-cols-*` compiles to
  # `minmax(0, 1fr)` tracks that never overflow — but that class only applies at
  # >= md. Below md (every phone) the grid has no explicit columns, so items land
  # in an implicit `auto` track that *respects each item's min-content*. A grid
  # item defaults to `min-width: auto`, so a single unbreakable/`truncate`
  # descendant (e.g. a threaded reply's `truncate` parent-excerpt in the feed)
  # gives the track a min-content equal to that full line and blows the whole
  # column past the viewport — every line then wraps at an off-screen edge and
  # looks clipped. Measured in a browser: 394px of overflow with `min-width: auto`,
  # 0 with `min-width: 0`.
  #
  # The fix is `min-w-0` on the main content column so it can shrink below its
  # content's min-content, exactly like the inner `min-w-0 flex-1` post-card
  # column already does. These are static source checks in the spirit of
  # `card_table_scroll_test.exs`.

  @web Path.expand("../../lib/vutuv_web", __DIR__)

  # {file, the col-span class that marks the main content column of a
  #  content+rail grid}
  @content_columns [
    {"live/post_live/feed.ex", "md:col-span-2"},
    {"templates/user/show.html.heex", "md:col-span-2"},
    {"templates/dev_doc/show.html.heex", "md:col-span-3"}
  ]

  test "each content+rail main column carries min-w-0 so it can shrink on a phone" do
    for {file, span} <- @content_columns do
      content = File.read!(Path.join(@web, file))

      # The class attribute that owns the main column (the one spanning the grid).
      class =
        case Regex.run(~r/class="([^"]*#{Regex.escape(span)}[^"]*)"/, content) do
          [_, class] -> class
          _ -> flunk("#{file}: no class attribute containing #{span}")
        end

      assert String.contains?(class, "min-w-0"),
             "#{file}: the main content column (class \"#{class}\") is missing " <>
               "min-w-0, so on a phone (below md, an implicit auto grid track) a " <>
               "long truncate/unbreakable descendant forces the column past the " <>
               "viewport and the page scrolls sideways"
    end
  end

  test "components.css lets rendered Markdown break long unbreakable tokens" do
    # A long unbreakable token (a pasted URL, a long word) in a post body has
    # `overflow-wrap: normal` by default and overflows its column on a phone
    # (measured: 589px of ink past a 300px box). `.markdown` must set
    # overflow-wrap so those tokens wrap instead. Code blocks keep `white-space:
    # pre` + `overflow-x: auto`, so they still scroll rather than wrap.
    css = File.read!(Path.expand("../../assets/css/components.css", __DIR__))

    assert Regex.match?(
             ~r/\.markdown\s*\{[^}]*overflow-wrap\s*:\s*(?:break-word|anywhere)/,
             css
           ),
           "components.css: `.markdown` must set overflow-wrap so a long " <>
             "unbreakable token in a post body wraps instead of overflowing the " <>
             "column on a phone"
  end
end
