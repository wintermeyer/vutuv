defmodule VutuvWeb.PostThreadLiveTest do
  @moduledoc """
  The permalink's embedded conversation LiveView (`VutuvWeb.PostLive.Thread`):
  a small thread renders whole (issue #1006 unchanged), a long one opens as a
  window around the permalinked post whose expanders load the rest over the
  socket — the issue #1033 follow-up that stopped the page from rendering
  hundreds of cards (and one action-bar LiveView per card).
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest
  import Vutuv.PostsHelpers

  alias Vutuv.Posts

  defp author(attrs \\ []), do: insert(:user, Keyword.merge([email_confirmed?: true], attrs))

  defp thread_view(post) do
    live_isolated(build_conn(), VutuvWeb.PostLive.Thread,
      session: %{"post_id" => post.id, "locale" => "en"}
    )
  end

  # A root post plus `count` direct replies, returned as {root, replies}.
  defp wide_thread(count) do
    user = author()
    root = create_post!(user, %{body: "the wide root"})

    replies =
      for i <- 1..count do
        {:ok, reply} = Posts.create_reply(author(), root, %{body: "wide reply #{i}"})
        reply
      end

    {root, replies}
  end

  # A root post plus a `depth`-deep chain of replies, each answering the
  # previous one. Returns {root, [c1, ..., cN]}.
  defp chain_thread(depth) do
    user = author()
    root = create_post!(user, %{body: "the chain root"})

    chain =
      Enum.reduce(1..depth, [root], fn i, [parent | _] = acc ->
        {:ok, reply} = Posts.create_reply(author(), parent, %{body: "chain reply #{i}"})
        [reply | acc]
      end)

    {root, chain |> Enum.reverse() |> tl()}
  end

  describe "small conversations (unchanged, issue #1006)" do
    test "a lone post renders as a single card without the thread frame" do
      post = create_post!(author(), %{body: "all alone here"})

      {:ok, _view, html} = thread_view(post)

      assert html =~ "all alone here"
      refute html =~ ~s(id="post-thread")
      refute html =~ "thread-focus"
    end

    test "a small thread renders whole, no expanders" do
      {root, replies} = wide_thread(3)

      {:ok, _view, html} = thread_view(root)

      assert html =~ ~s(id="post-thread")
      for reply <- replies, do: assert(html =~ reply.body)
      refute html =~ ~s(id="thread-more")
      refute html =~ ~s(id="thread-earlier")
    end
  end

  describe "a long conversation opens as a window" do
    test "the focus's replies come chunked; the expander loads the next chunk" do
      {root, replies} = wide_thread(30)

      {:ok, view, html} = thread_view(root)

      # The first chunk (20) is on the page, the tail is not.
      assert html =~ "wide reply 1</p>" or html =~ "wide reply 1"
      assert html =~ Enum.at(replies, 19).body
      refute html =~ Enum.at(replies, 20).body

      # The expander names what it hides and loads it over the socket.
      assert html =~ ~s(id="thread-more")
      assert html =~ "Show 10 more replies"

      html = view |> element("#thread-more") |> render_click()
      assert html =~ Enum.at(replies, 29).body
      refute html =~ ~s(id="thread-more")
    end

    test "a deep ancestor chain collapses to root + gap + nearest ancestors" do
      {_root, chain} = chain_thread(30)
      focus = List.last(chain)

      {:ok, view, html} = thread_view(focus)

      # Root pinned, the three nearest ancestors shown, the middle elided.
      assert html =~ "the chain root"
      assert html =~ "chain reply 29"
      assert html =~ "chain reply 27"
      refute html =~ "chain reply 26</p>"
      refute html =~ "chain reply 2</p>"

      # The permalinked post is the tinted subject, scrolled to on arrival.
      assert html =~ ~s(id="thread-focus")
      assert html =~ "data-thread-scroll"

      # 30 ancestors: root + 3 shown -> 26 elided.
      assert html =~ "Show 26 earlier posts"

      html = view |> element("#thread-earlier") |> render_click()
      assert html =~ "chain reply 17"
      assert html =~ "Show 16 earlier posts"
    end

    test "sibling branches stay off the page but are counted, with a way in" do
      {root, _replies} = wide_thread(30)
      {:ok, aside} = Posts.create_reply(author(), root, %{body: "the aside branch"})
      {:ok, focus} = Posts.create_reply(author(), aside, %{body: "the deep focus"})

      {:ok, _view, html} = thread_view(focus)

      # The window: root, parent, focus — none of the 30 sibling replies.
      assert html =~ "the wide root"
      assert html =~ "the aside branch"
      assert html =~ "the deep focus"
      refute html =~ "wide reply 5"

      # The rest of the conversation is one link away, at the root.
      assert html =~ "part of a conversation with"
      assert html =~ "33"
      assert html =~ ~s(id="thread-from-start")
      assert html =~ Posts.path(root)
    end
  end

  describe "live counters inside the thread host" do
    test "another viewer's like ticks the shown card's counter" do
      {root, replies} = wide_thread(2)
      shown = hd(replies)

      {:ok, view, _html} = thread_view(root)

      :ok = Posts.like_post(author(), shown)

      # The host forwards the broadcast to the card's in-process bar.
      assert render(view) =~ ~r/data-count="like">\s*1\s*</
    end
  end
end
