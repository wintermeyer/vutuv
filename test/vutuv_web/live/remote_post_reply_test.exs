defmodule VutuvWeb.RemotePostReplyTest do
  @moduledoc """
  The page for answering a post by an account somebody follows on another
  network (issue #1165), and the Reply affordance that leads to it.

  What is under test here is mostly what the page refuses to do quietly: it says
  where the words are going before anybody types, it offers no answer at all on
  a followers-only post, and it explains rather than hides the one refusal a
  member can act on.

  `async: false` — the outbound reply budget lives in the shared
  `Vutuv.RateLimiter` ETS table, which the SQL sandbox does not roll back.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost

  @actor "https://social.example/users/them"

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  defp account do
    Repo.insert!(%RemoteAccount{
      actor_uri: @actor,
      host: "social.example",
      handle: "them",
      name: "Them Themself",
      inbox_uri: @actor <> "/inbox"
    })
  end

  defp cached_post(acc, audience \\ "public") do
    now = DateTime.utc_now(:second)

    Repo.insert!(%RemotePost{
      remote_account_id: acc.id,
      object_uri: "https://social.example/p/#{System.unique_integer([:positive])}",
      origin_url: "https://social.example/@them/1",
      content_text: "Eine Frage in die Runde.",
      audience: audience,
      kind: "note",
      published_at: now,
      received_at: now,
      expires_at: DateTime.add(now, 86_400)
    })
  end

  defp follow(user, acc) do
    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: acc.id,
      state: "accepted",
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#f/#{acc.id}"
    })
  end

  defp federating(user) do
    user |> Ecto.Changeset.change(fediverse_followers?: true) |> Repo.update!()
    {:ok, _actor} = Fediverse.ensure_actor(user)
    Repo.reload!(user)
  end

  describe "the Reply affordance" do
    test "a public post from a followed account offers one", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      acc = account()
      follow(user, acc)
      post = cached_post(acc)

      {:ok, view, _html} = live(conn, ~p"/feed")

      assert has_element?(view, "[data-remote-reply-link='#{post.id}']")
    end

    test "a followers-only post offers none", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      acc = account()
      follow(user, acc)
      post = cached_post(acc, "followers")

      {:ok, view, _html} = live(conn, ~p"/feed")

      # No control rather than one that refuses: the answer would be a public
      # vutuv post quoting a restricted context.
      assert has_element?(view, "[data-remote-post='#{post.id}']")
      refute has_element?(view, "[data-remote-reply-link='#{post.id}']")
    end
  end

  describe "the page" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      acc = account()
      follow(user, acc)
      %{conn: conn, user: federating(user), account: acc, post: cached_post(acc)}
    end

    test "says where the words are going before anybody types", ctx do
      {:ok, view, html} = live(ctx.conn, ~p"/system/fediverse/reply/post/#{ctx.post.id}")

      assert has_element?(view, "[data-remote-reply-notice]")
      assert html =~ "@them@social.example"
      # And it shows the post being answered, so nobody replies blind.
      assert has_element?(view, "[data-remote-post='#{ctx.post.id}']")
      # No feed chrome: nothing here handles `close-composer`, so rendering the
      # feed's ✕ would give the page a button that kills it.
      refute has_element?(view, "#composer [phx-click='close-composer']")
    end

    test "sending creates a top-level post carrying the post it answers", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/system/fediverse/reply/post/#{ctx.post.id}")

      view
      |> form("#composer form", post: %{body: "Meine Antwort."})
      |> render_submit()

      assert [post] = Repo.all(from(p in Vutuv.Posts.Post, where: p.user_id == ^ctx.user.id))
      assert post.body == "Meine Antwort."

      {:ok, view, html} = live(ctx.conn, ~p"/feed")
      assert html =~ "Meine Antwort."

      # One row for the conversation: the answer carries the post it answers
      # above it, and that post gives up the row its own author's follow would
      # otherwise give it — so it is on the page exactly once.
      assert has_element?(view, "#feed-post-#{post.id} [data-remote-post='#{ctx.post.id}']")
    end

    test "the replying-to line names the account here, not out there", ctx do
      # The line is what a card without the answered post above it wears, and
      # the profile is such a surface: it draws flat cards and pulls in no
      # parent from another network.
      {:ok, view, _html} = live(ctx.conn, ~p"/system/fediverse/reply/post/#{ctx.post.id}")

      view
      |> form("#composer form", post: %{body: "Meine Antwort."})
      |> render_submit()

      {:ok, view, html} = live(ctx.conn, ~p"/#{ctx.user}")
      assert html =~ "data-reply-banner=\"remote\""
      assert html =~ "@them@social.example"

      # It names who is being answered, so it links to that account's page
      # here — not out to their server, and not to a compose form.
      assert has_element?(
               view,
               "[data-reply-banner='remote'] a[href='/system/fediverse/account/#{ctx.account.id}']"
             )
    end

    test "a followers-only post is refused even when the URL is typed by hand", ctx do
      restricted = cached_post(ctx.account, "followers")

      assert {:error, {:redirect, %{to: "/feed", flash: flash}}} =
               live(ctx.conn, ~p"/system/fediverse/reply/post/#{restricted.id}")

      assert flash["error"] =~ "followers"
    end

    test "an unknown id is a 404, so nothing leaks", ctx do
      assert {:error, {:redirect, %{to: "/"}}} =
               live(ctx.conn, ~p"/system/fediverse/reply/post/#{Vutuv.UUIDv7.generate()}")
    end
  end

  test "a member who does not federate gets the explanation, not a dead end", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    acc = account()
    follow(user, acc)
    post = cached_post(acc)

    {:ok, view, html} = live(conn, ~p"/system/fediverse/reply/post/#{post.id}")

    # The page explains and links to the switch; hiding the action would leave
    # them no way to find out that answering exists.
    assert html =~ "Fediverse"
    assert has_element?(view, "a[href='/settings/fediverse']")
    refute has_element?(view, "#composer")
  end
end
