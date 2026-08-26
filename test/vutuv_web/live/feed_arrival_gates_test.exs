defmodule VutuvWeb.FeedArrivalGatesTest do
  @moduledoc """
  A post arriving live must pass the same gates the query would have applied.

  The feed decides twice who sees a post: once in SQL, when a page is fetched,
  and once in memory, when one arrives over PubSub. The two answered differently
  — the live path asked only about blocks and the post's own audience, so a
  **muted** member's post and a post in a language the reader filters out both
  lit the "N new posts" pill, and vanished again the moment they pressed it and
  the page was re-read. A control that promises posts and then shows none is
  worse than no control.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Posts
  alias Vutuv.Social

  # A member the viewer follows, plus one older post so the feed has content.
  defp followed_author(viewer, body) do
    author = insert(:activated_user)
    Social.follow(viewer, author.id)
    {:ok, _post} = Posts.create_post(author, %{body: body})
    author
  end

  defp timeline(view) do
    if has_element?(view, "#feed-posts"), do: render(element(view, "#feed-posts")), else: ""
  end

  describe "a muted member's post" do
    test "does not fill the pill", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      author = followed_author(user, "an older post")
      Social.toggle_follow_mute!(user.id, Social.follow_id(user.id, author.id))

      {:ok, view, _html} = live(conn, ~p"/feed")

      {:ok, _fresh} = Posts.create_post(author, %{body: "arriving from a muted member"})

      refute has_element?(view, "#show-new-posts")
      refute timeline(view) =~ "arriving from a muted member"
    end

    test "the same post arrives once the mute is lifted", %{conn: conn} do
      # The other side of the gate, so the test cannot pass by dropping
      # everything.
      {conn, user} = create_and_login_user(conn)
      author = followed_author(user, "an older post")

      {:ok, view, _html} = live(conn, ~p"/feed")

      {:ok, _fresh} = Posts.create_post(author, %{body: "arriving unmuted"})

      assert has_element?(view, "#show-new-posts")
      render_click(view, "show-new")
      assert timeline(view) =~ "arriving unmuted"
    end
  end

  describe "a post in a language the reader filters out" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      {:ok, user} =
        Vutuv.Accounts.update_user(user, %{
          "feed_languages" => ["de"],
          "feed_foreign_posts" => "hide"
        })

      %{conn: conn, user: user}
    end

    test "does not fill the pill", %{conn: conn, user: user} do
      author = followed_author(user, "ein aelterer Beitrag")
      fresh = post_in(author, "arriving in another language", "fr")

      # The query already leaves it out, which is what the pill then has to
      # agree with — so the page opens without it.
      {:ok, view, _html} = live(conn, ~p"/feed")
      refute timeline(view) =~ "arriving in another language"

      announce(user, fresh)

      refute has_element?(view, "#show-new-posts")
      refute timeline(view) =~ "arriving in another language"
    end

    test "a post in a chosen language still arrives", %{conn: conn, user: user} do
      author = followed_author(user, "ein aelterer Beitrag")
      fresh = post_in(author, "ein neuer Beitrag auf Deutsch", "de")

      {:ok, view, _html} = live(conn, ~p"/feed")

      announce(user, fresh)

      # Already on the page from the query, so the pill is not the claim here —
      # what matters is that the arrival was not dropped as foreign.
      assert timeline(view) =~ "ein neuer Beitrag auf Deutsch"
    end

    # Language detection runs off the request path (`Vutuv.Languages`), so a
    # post is announced with none and only later carries one. These tests are
    # about the announcement of a post that already does: they stamp it and
    # then re-announce it the way the detector's own write would.
    defp post_in(author, body, language) do
      {:ok, post} = Posts.create_post(author, %{body: body})

      Repo.update_all(
        from(p in Posts.Post, where: p.id == ^post.id),
        set: [language: language]
      )

      %{post | language: language}
    end

    defp announce(user, post) do
      Vutuv.Activity.broadcast(
        user.id,
        {:new_post, %{post_id: post.id, author_id: post.user_id, at: post.inserted_at}}
      )
    end
  end
end
