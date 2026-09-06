defmodule VutuvWeb.FeedEdgeToEdgeTest do
  @moduledoc """
  The feed's timeline on a phone: no page gutter, no card padding, no avatar
  column under the text.

  A 390px screen was spending 88px of its width before a post's first word (16px
  gutter + 24px card padding + 48px avatar column), which left the body reading
  at 262px. Below `md` the card now runs to both edges of the screen, its side
  padding sits on each **row** so the hairline between two posts does too, the
  header row keeps the avatar beside it while everything under it starts at the
  card's left edge, and a picture breaks back out to the real edge.

  All of it hangs off `data-` markers in the markup and one `@media (width <
  48rem)` block at the end of `app.css`, so this file checks the two ends of
  that contract: the markers are where the selectors expect them, and the
  selectors are still there. It reads the stylesheet **with the comments
  stripped**, the way `mobile_tab_bar_css_test.exs` and its siblings do — every
  selector here is also written out in the block's own prose, so a raw scan
  would pass on a stylesheet that had lost the rules and kept the explanation.

  The scope is the other half. `data-timeline-flush` is `<.card flush>`, which
  only `/feed` asks for; the carded post lists that are *not* the feed (the
  posts archive, the saved hub, a tag timeline) keep the inset reading, and the
  archive is what the scope test renders — a profile's Posts section would pass
  either way, being `card={false}` and inset under any rule.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Vutuv.Posts

  @app_css Path.expand("../../assets/css/app.css", __DIR__)
  @components_css Path.expand("../../assets/css/components.css", __DIR__)
  @components Path.expand("../../lib/vutuv_web/components/post_components.ex", __DIR__)
  @ui Path.expand("../../lib/vutuv_web/components/ui.ex", __DIR__)

  describe "the feed's timeline" do
    test "carries every marker the stylesheet places by", %{conn: conn} do
      live = feed_with_a_conversation(conn)

      assert has_element?(live, "section[data-timeline-flush] [data-timeline-rows]#feed-posts"),
             "The feed's post list is the one card that runs edge to edge on a phone. It " <>
               "renders through `<.post_list flush>` → `<.card flush>`; the side padding " <>
               "then sits on the rows, so the hairline between two posts reaches both edges."

      assert has_element?(live, "#feed-posts [data-card-head] > [data-card-column]"),
             "Below `md` the column becomes `display: contents` so its children are the " <>
               "head grid's own items. The rule is written `[data-card-head] > " <>
               "[data-card-column]`, so the two have to stay parent and child."

      assert has_element?(live, "#feed-posts [data-thread-reply]"),
             "An answer takes a 2px rail below `md`, where the avatar column the " <>
               "connectors are drawn in is gone."

      assert has_element?(live, "#feed-posts [data-thread-reply] [data-thread-connector]"),
             "The connectors keep a marker of their own: the stylesheet takes them away " <>
               "below `md` rather than the markup dropping them, so a desktop is untouched."
    end
  end

  describe "scope" do
    test "a carded post list that is not the feed stays inset", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      {:ok, _post} = Posts.create_post(user, %{body: "Im Archiv."})

      html = conn |> get(~p"/#{user}/posts") |> html_response(200)

      assert html =~ "data-timeline-rows",
             "The posts archive renders a carded `<.post_list>`, so it is the surface that " <>
               "would go edge to edge if `flush` ever became the default for a carded list."

      assert html =~ "data-card-head",
             "The card's own shape is the same everywhere — only the surface differs."

      refute html =~ "data-timeline-flush",
             "Only the feed's timeline runs edge to edge. Everything else keeps the inset " <>
               "card, because there the card shape is what says where the section ends."
    end
  end

  describe "the stylesheet" do
    test "still has a rule for every selector the markup is written for" do
      css = app_css()

      for selector <- [
            "[data-timeline-flush] {",
            "[data-timeline-flush] > [data-timeline-rows] > * {",
            "[data-card-head] {",
            "[data-card-head] > [data-card-column] {",
            "[data-thread-reply] {",
            "[data-thread-connector] {",
            "[data-timeline-flush] [data-thread-reply] [data-media-edge] {"
          ] do
        assert String.contains?(css, selector),
               "`assets/css/app.css` has lost the rule for `#{selector}`. The phone " <>
                 "timeline is one block of attribute-keyed rules, and the markup carries " <>
                 "the marker either way — a missing rule is silent."
      end
    end

    test "places the header row beside the avatar and everything else across both tracks" do
      css = app_css()

      assert css =~ ~r/\[data-card-head\] > \[data-card-column\] > \* \{\s*grid-column: 1 \/ -1;/,
             "Everything under the header row spans both tracks — that is the 48px this " <>
               "block exists to reclaim."

      assert css =~
               ~r/\[data-card-head\] > \[data-card-column\] > :first-child \{\s*grid-column: 2;\s*min-width: 0;/,
             "The header row is the one child that stays beside the avatar, and it needs " <>
               "`min-width: 0` or a 255-character remote handle scrolls the page sideways."
    end

    test "sits below md and outside every cascade layer" do
      assert String.contains?(app_css(), "@media (width < 48rem) {"),
             "The block is phone-only: from `md` up the card keeps the avatar column."

      refute String.contains?(strip_comments(@components_css), "data-card-head"),
             "`components.css` sits in the `components` layer, which loses to the utilities " <>
               "layer whatever its specificity — and every rule here has a utility on the " <>
               "same element to beat (`p-6`, `rounded-2xl`, `flex`, `pl-7`). It belongs in " <>
               "`app.css`, unlayered."
    end

    test "the rail has a dark step" do
      assert String.contains?(
               app_css(),
               "@media (prefers-color-scheme: dark) and (width < 48rem) {"
             ),
             "`slate-200` on a `slate-900` card is not a line anybody can see. The rail's " <>
               "dark colour needs its own width-scoped query: the file's dark block at the " <>
               "end is not width-scoped, and at desktop widths there is no rail to colour."
    end

    test "negates the page gutter the rest of the app pads with" do
      for side <- ~w(left right) do
        assert String.contains?(app_css(), "max(1rem, env(safe-area-inset-#{side}))"),
               "The flush card cancels the page gutter, so it has to spell the same value."

        assert String.contains?(File.read!(@ui), "max(1rem,env(safe-area-inset-#{side}))"),
               "`UI.gutter_class/0` no longer pads with `max(1rem, env(safe-area-inset-" <>
                 "#{side}))`, but the phone-timeline block in `app.css` still negates that " <>
                 "amount — the timeline would sit a few pixels off one edge on every phone. " <>
                 "Change both, or give them one custom property."
      end
    end
  end

  describe "the markers themselves" do
    test "every card head has the column the rule pairs it with" do
      source = File.read!(@components)
      heads = count(source, ~s|data-card-head class=|)
      columns = count(source, ~s|data-card-column class=|)

      assert heads == columns,
             "`post_components.ex` has #{heads} card heads and #{columns} columns. The " <>
               "stylesheet places by `[data-card-head] > [data-card-column]`, so a head " <>
               "without its column renders the header row under the avatar instead of " <>
               "beside it."

      assert heads >= 3,
             "A timeline draws three kinds of card — a member's post, a cached post from " <>
               "another network, and a reply from one — and all three wear this head."
    end

    test "every full-width picture on a card says it may reach the edge" do
      sites =
        count(File.read!(@components), "data-media-edge") +
          count(
            File.read!(
              Path.expand("../../lib/vutuv_web/components/video_components.ex", __DIR__)
            ),
            "data-media-edge"
          )

      assert sites >= 6,
             "The six that break out of the row's padding: a link screenshot, a fediverse " <>
               "photo, a member's single photo, the mosaic of several, the tiles standing " <>
               "in for a photo the AI scan still holds, and a clip. Add the marker with " <>
               "the picture, or one card's photo stops 16px short of the edge beside " <>
               "another's that does not — and a held photo jumps to the edge when it clears."
    end
  end

  # A reader, somebody they follow, and a conversation on the page: one post
  # with one answer, which is what draws a head, a column, a rail and a
  # connector in one render.
  defp feed_with_a_conversation(conn) do
    {conn, user} = create_and_login_user(conn)
    friend = insert(:activated_user)
    insert(:follow, follower: user, followee: friend)

    {:ok, parent} = Posts.create_post(friend, %{body: "Der Beitrag, auf den geantwortet wird."})
    {:ok, _reply} = Posts.create_reply(friend, parent, %{body: "Und die Antwort darauf."})

    {:ok, live, _html} = live(conn, ~p"/feed")
    live
  end

  # Comments name every selector in this block, so an assertion against the raw
  # file would pass on a stylesheet that kept the prose and lost the rules.
  defp app_css, do: strip_comments(@app_css)

  defp strip_comments(path) do
    Regex.replace(~r{/\*.*?\*/}s, File.read!(path), "")
  end

  defp count(haystack, needle), do: haystack |> String.split(needle) |> length() |> Kernel.-(1)
end
