defmodule VutuvWeb.FeedMuteMenuTest do
  @moduledoc """
  The two ways out a boost card offers, on the feed.

  The reported case: a member follows Doris, Doris boosts Lilly every day, and
  Lilly is an account nobody here follows. Before this the card's ⋯ menu offered
  Report (which deletes our one cached copy for everybody) or unfollowing Doris,
  and its Mute item was hidden because there was no follow row to write to.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  import Vutuv.MastodonHelpers, only: [remote_account: 1, cached_post: 2]

  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.PostBoost
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Mutes

  # Through the shared helper, which mints a unique `actor_uri` per call: a
  # literal one in an `async: true` file convoys on its unique index with every
  # other file that spells the same address, which is the deadlock the test
  # rules warn about.
  defp account(handle), do: remote_account(handle: handle, name: String.capitalize(handle))

  defp follow(user, account) do
    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: "accepted",
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#f/#{account.id}"
    })
  end

  defp boost(booster, post) do
    Repo.insert!(%PostBoost{
      remote_account_id: booster.id,
      remote_post_id: post.id,
      activity_id: "https://friendica.example/act/#{System.unique_integer([:positive])}",
      announced_at: DateTime.utc_now(:second)
    })
  end

  defp boosted_feed(conn) do
    {conn, user} = create_and_login_user(conn)
    doris = account("doris")
    lilly = account("lilly")
    follow(user, doris)
    boost(doris, cached_post(lilly, content_text: "Lillys Tagebuch"))
    cached_post(doris, content_text: "Doris schreibt selbst")

    {:ok, view, _html} = live(conn, ~p"/feed")
    %{view: view, user: user, doris: doris, lilly: lilly}
  end

  test "muting the boosted author takes the card away and leaves the booster", %{conn: conn} do
    %{view: view, user: user, doris: doris, lilly: lilly} = boosted_feed(conn)

    assert render(view) =~ "Lillys Tagebuch"

    view
    |> element("[phx-click='mute-remote-account'][phx-value-id='#{lilly.id}']")
    |> render_click()

    refute render(view) =~ "Lillys Tagebuch"
    assert render(view) =~ "Doris schreibt selbst"
    assert Mutes.scope_for(user, lilly) == :all
    assert Mutes.scope_for(user, doris) == nil
  end

  test "hiding the booster's reposts keeps the booster's own posts", %{conn: conn} do
    %{view: view, user: user, doris: doris} = boosted_feed(conn)

    view
    |> element("[phx-click='mute-remote-reposts'][phx-value-id='#{doris.id}']")
    |> render_click()

    refute render(view) =~ "Lillys Tagebuch"
    assert render(view) =~ "Doris schreibt selbst"
    assert Mutes.scope_for(user, doris) == :reposts

    # And the follow itself is untouched — the whole point of the narrow scope.
    refute Repo.get_by!(Follow, user_id: user.id, remote_account_id: doris.id).muted
  end

  # The local card's menu is links, not events (it has to work on a dead page),
  # so what matters is the href it renders — a hand-built path in a test proves
  # nothing about the control a member actually presses.
  test "a member's reshare offers both mutes, and the rendered hrefs work", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    resharer = insert(:activated_user)
    stranger = insert(:activated_user)
    {:ok, _} = Vutuv.Social.follow(user, resharer.id)
    post = Vutuv.PostsHelpers.create_post!(stranger, %{body: "Vom Fremden"})
    :ok = Vutuv.Posts.repost_post(Repo.reload!(resharer), post)

    {:ok, view, _html} = live(conn, ~p"/feed")
    html = render(view)

    mute_author = href_for(html, "kind=member&amp;id=#{stranger.id}")
    hide_reposts = href_for(html, "kind=member&amp;id=#{resharer.id}&amp;scope=reposts")

    assert mute_author, "the card offers no Mute for an author nobody follows"
    assert hide_reposts, "the card offers no way to hide the resharer's reposts"

    conn = conn |> recycle() |> post(mute_author)
    assert redirected_to(conn) =~ "/"
    assert Mutes.scope_for(user, stranger) == :all

    conn = conn |> recycle() |> post(hide_reposts)
    assert redirected_to(conn) =~ "/"
    assert Mutes.scope_for(user, resharer) == :reposts
  end

  # The href as the page really rendered it, entities and all.
  defp href_for(html, needle) do
    case Regex.run(~r/href="([^"]*#{Regex.escape(needle)}[^"]*)"/, html) do
      [_, href] -> href |> String.replace("&amp;", "&")
      nil -> nil
    end
  end

  test "each item spells the handle it acts on under its label", %{conn: conn} do
    %{view: view, doris: doris, lilly: lilly} = boosted_feed(conn)

    hide =
      view
      |> element("[phx-click='mute-remote-reposts'][phx-value-id='#{doris.id}']")
      |> render()

    mute =
      view
      |> element("[phx-click='mute-remote-account'][phx-value-id='#{lilly.id}']")
      |> render()

    # The hint line is what tells the reader which of the two accounts on this
    # card the item is about — the whole reason both items can sit in one menu.
    assert hide =~ RemoteAccount.display_handle(doris)
    refute hide =~ RemoteAccount.display_handle(lilly)
    assert mute =~ RemoteAccount.display_handle(lilly)
  end

  test "the repost item names the booster, not the author", %{conn: conn} do
    %{view: view, doris: doris, lilly: lilly} = boosted_feed(conn)

    assert has_element?(view, "[phx-click='mute-remote-reposts'][phx-value-id='#{doris.id}']")
    refute has_element?(view, "[phx-click='mute-remote-reposts'][phx-value-id='#{lilly.id}']")
    # And Mute is offered for the author nobody here follows, which is the item
    # that was missing.
    assert has_element?(view, "[phx-click='mute-remote-account'][phx-value-id='#{lilly.id}']")
  end
end
