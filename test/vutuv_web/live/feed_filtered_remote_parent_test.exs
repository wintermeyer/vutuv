defmodule VutuvWeb.PostLive.FeedFilteredRemoteParentTest do
  @moduledoc """
  A word filter against the post from **another network** that a member's answer
  carries above it.

  The sibling of `FeedFilteredThreadTest`, one world over. The filter check
  looked at the vutuv posts a row draws (`Posts.thread_posts/1`) and at a remote
  entry standing on its own, and at nothing in between — so a cached post
  carrying a muted word was never checked in the place it is actually drawn in
  full, as the head of somebody's answer.

  That was survivable while such a post also held a row of its own, which the
  check *did* see and fold. Since the conversation started winning that tie
  (2026-09-01) the checked copy is gone, so the row is the only copy and it has
  to be checked here.

  Not async: answering a post out there claims from `Vutuv.RateLimiter`, a
  shared ETS table the SQL sandbox does not roll back.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Vutuv.ContentFilters
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Posts
  alias Vutuv.Social

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  defp cached_post(body) do
    now = DateTime.utc_now(:second)
    unique = System.unique_integer([:positive])

    account =
      Repo.insert!(%RemoteAccount{
        actor_uri: "https://social.example/users/them#{unique}",
        host: "social.example",
        handle: "them#{unique}",
        name: "Thea Remote",
        inbox_uri: "https://social.example/users/them#{unique}/inbox"
      })

    Repo.insert!(%RemotePost{
      remote_account_id: account.id,
      object_uri: "https://social.example/p/#{unique}",
      origin_url: "https://social.example/@them/#{unique}",
      content_text: body,
      audience: "public",
      kind: "note",
      published_at: now,
      received_at: now,
      expires_at: DateTime.add(now, 86_400)
    })
    |> Repo.preload(:remote_account)
  end

  test "a muted word in the answered post folds the row it arrived in", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)

    answerer = insert(:activated_user, fediverse_followers?: true)
    {:ok, _actor} = Fediverse.ensure_actor(answerer)
    Social.follow(user, answerer.id)

    remote = cached_post("Die Zeugnisanalyse funktioniert hervorragend.")

    {:ok, _post} =
      Posts.create_remote_post_reply(Repo.reload!(answerer), remote, %{
        body: "Danke für Dein Feedback!"
      })

    {:ok, _} = ContentFilters.create_filter(user, %{kind: :keyword, pattern: "Zeugnis*"})

    {:ok, live, _html} = live(conn, ~p"/feed")

    refute render(live) =~ "Die Zeugnisanalyse funktioniert hervorragend."
    assert has_element?(live, "#feed-posts [data-filtered-post]")

    # And it opens, like every other folded row: the filter hides, it does not
    # delete.
    live |> element("#feed-posts [data-filtered-post] button") |> render_click()
    assert render(live) =~ "Die Zeugnisanalyse funktioniert hervorragend."
  end
end
