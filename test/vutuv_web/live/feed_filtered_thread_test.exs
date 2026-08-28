defmodule VutuvWeb.PostLive.FeedFilteredThreadTest do
  @moduledoc """
  A word filter against a post that reaches the feed as part of a conversation.

  The feed does not render a reply on its own: it renders the thread, the answer
  plus the posts it answers. The filter check only ever looked at the entry's own
  post, so a post carrying a muted word walked onto the page in full whenever
  somebody replied to it — which is the normal fate of exactly the posts worth
  arguing about (reported 2026-08-28: "Zeugnis*" was set and "Die Zeugnisanalyse
  funktioniert hervorragend" sat in the feed).

  The reader's own post keeps its exemption per post, not per entry, or replying
  once to a muted conversation would silently reopen it.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Vutuv.ContentFilters
  alias Vutuv.Posts

  defp hide(user, pattern) do
    {:ok, _} = ContentFilters.create_filter(user, %{kind: :keyword, pattern: pattern})
    :ok
  end

  test "an ancestor carrying a muted word folds the row it arrived in", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    friend = insert(:activated_user, first_name: "Jörg", last_name: "Kastning")
    insert(:follow, follower: user, followee: friend)

    {:ok, parent} =
      Posts.create_post(friend, %{body: "Die Zeugnisanalyse funktioniert hervorragend."})

    {:ok, _reply} = Posts.create_reply(user, parent, %{body: "Danke für Dein Feedback!"})

    hide(user, "Zeugnis*")

    {:ok, live, _html} = live(conn, ~p"/feed")

    refute render(live) =~ "Die Zeugnisanalyse funktioniert hervorragend."
    assert has_element?(live, "#feed-posts [data-filtered-post]")

    # The folded row says whose post it was. Without that the reader has to open
    # it to find out whether opening it is worth it, which is the one thing the
    # fold is meant to spare them — and the name has to be the *matching* post's
    # author, an ancestor here, not the reply the row is keyed on.
    assert has_element?(live, "[data-filtered-post]", "Jörg Kastning")
    refute has_element?(live, "[data-filtered-post]", "Danke für Dein Feedback")

    # And it opens, like every other folded row — the filter hides, it does not
    # delete, and a conversation the reader is part of has to be reachable.
    live |> element("#feed-posts [data-filtered-post] button") |> render_click()
    assert render(live) =~ "Die Zeugnisanalyse funktioniert hervorragend."
  end

  test "the reader's own post is not what folds a row", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    friend = insert(:activated_user)
    insert(:follow, follower: user, followee: friend)

    {:ok, parent} = Posts.create_post(friend, %{body: "Wie läuft es denn so?"})
    {:ok, _reply} = Posts.create_reply(user, parent, %{body: "Die Zeugnisanalyse läuft gut."})

    hide(user, "Zeugnis*")

    {:ok, live, _html} = live(conn, ~p"/feed")

    assert render(live) =~ "Die Zeugnisanalyse läuft gut."
    refute has_element?(live, "#feed-posts [data-filtered-post]")
  end
end
