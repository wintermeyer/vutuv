defmodule VutuvWeb.FediverseAccountLiveTest do
  @moduledoc """
  The page for one account on another network (`/system/fediverse/account/:id`,
  issue #1162): who may open it, what it shows, the follow round trip, and the
  entry points that now lead here instead of off the site.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost

  @actor "https://social.example/users/them"

  defp account do
    Repo.insert!(%RemoteAccount{
      actor_uri: @actor,
      host: "social.example",
      handle: "them",
      name: "Them Themself",
      summary: "Schreibt über Züge.",
      inbox_uri: @actor <> "/inbox"
    })
  end

  defp follow(user, account, state \\ "accepted") do
    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: state,
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#follows/#{account.id}"
    })
  end

  defp cached_post(account, attrs \\ %{}) do
    now = DateTime.utc_now(:second)

    Repo.insert!(
      struct(
        %RemotePost{
          remote_account_id: account.id,
          object_uri: "https://social.example/posts/#{System.unique_integer([:positive])}",
          content_text: "Ein Beitrag von drüben.",
          audience: "public",
          kind: "note",
          published_at: now,
          received_at: now,
          expires_at: DateTime.add(now, 86_400)
        },
        attrs
      )
    )
  end

  test "an anonymous visitor is sent away", %{conn: conn} do
    acc = account()

    conn = get(conn, ~p"/system/fediverse/account/#{acc.id}")
    assert redirected_to(conn) == ~p"/login"
  end

  test "robots are told not to index it", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    acc = account()

    conn = get(conn, ~p"/system/fediverse/account/#{acc.id}")

    # Assembled from what other people wrote on other servers: not ours to
    # publish, and never a crawlable directory of who reacted to a post here.
    assert [robots] = Plug.Conn.get_resp_header(conn, "x-robots-tag")
    assert robots =~ "noindex"
  end

  test "an unknown id lands somewhere sensible instead of crashing", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    assert {:error, {:redirect, %{to: "/feed"}}} =
             live(conn, ~p"/system/fediverse/account/019fa2ba-b301-771a-8bbf-efd42278fd8a")
  end

  test "it shows who the account is and offers the follow", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    {:ok, user} = Vutuv.Accounts.update_user(user, %{"fediverse_followers?" => "true"})
    {:ok, _actor} = Fediverse.ensure_actor(user)
    acc = account()

    {:ok, view, html} = live(conn, ~p"/system/fediverse/account/#{acc.id}")

    assert html =~ "Them Themself"
    assert html =~ "@them@social.example"
    assert has_element?(view, "[data-remote-summary]")
    # The real thing stays one click away.
    assert has_element?(view, "[data-remote-origin][href='#{@actor}']")
    assert has_element?(view, "#follow")
  end

  test "an account nobody follows says why it has no posts", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    acc = account()

    {:ok, view, _html} = live(conn, ~p"/system/fediverse/account/#{acc.id}")

    # Not "this account never posts": we hold posts only while somebody here
    # follows, and this page fetches nothing.
    assert has_element?(view, "#no-posts")
  end

  test "the follow state reads honestly and round-trips with no reload", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    {:ok, user} = Vutuv.Accounts.update_user(user, %{"fediverse_followers?" => "true"})
    {:ok, _actor} = Fediverse.ensure_actor(user)
    acc = account()
    follow(user, acc, "requested")

    {:ok, view, _html} = live(conn, ~p"/system/fediverse/account/#{acc.id}")

    assert has_element?(view, "[data-follow-state=requested]")

    view |> element("#unfollow") |> render_click()

    assert has_element?(view, "#follow")
    assert Repo.aggregate(Follow, :count) == 0
  end

  test "muting is reversible, and this page is where it reverses", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    {:ok, user} = Vutuv.Accounts.update_user(user, %{"fediverse_followers?" => "true"})
    {:ok, _actor} = Fediverse.ensure_actor(user)
    acc = account()
    follow(user, acc)

    {:ok, view, _html} = live(conn, ~p"/system/fediverse/account/#{acc.id}")

    view |> element("#toggle-mute") |> render_click()

    assert has_element?(view, "[data-follow-muted]")
    assert Repo.get_by!(Follow, user_id: user.id).muted

    # The whole point: muting from the feed takes the account's posts away, and
    # with them the menu that muted it. Without a way back the flash promising
    # "you still follow them" describes a door that only opens one way.
    view |> element("#toggle-mute") |> render_click()

    refute has_element?(view, "[data-follow-muted]")
    refute Repo.get_by!(Follow, user_id: user.id).muted
  end

  test "the empty Posts card says something true for each follow state", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    acc = account()

    # Nobody follows: the copies only exist while somebody does.
    {:ok, view, _html} = live(conn, ~p"/system/fediverse/account/#{acc.id}")
    assert render(view) =~ "posts while somebody here follows it"

    # A requested follow with a followers-only post cached: we DO hold posts, so
    # "nobody here follows this account" would be false.
    cached_post(acc, %{audience: "followers"})
    follow(user, acc, "requested")

    {:ok, view, _html} = live(conn, ~p"/system/fediverse/account/#{acc.id}")
    assert has_element?(view, "#no-posts")
    assert render(view) =~ "Waiting for that server"
  end

  test "there is a way to the real profile even when nothing is cached", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    acc = account()

    {:ok, view, _html} = live(conn, ~p"/system/fediverse/account/#{acc.id}")

    # Otherwise the empty page is a dead end, and "a preview here, the whole
    # person over there" is only in the moduledoc.
    assert has_element?(view, "a[href='#{@actor}']")
    assert render(view) =~ "social.example"
  end

  test "a member who does not federate is told why, not shown a dead button", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    acc = account()

    {:ok, view, _html} = live(conn, ~p"/system/fediverse/account/#{acc.id}")

    assert has_element?(view, "#cannot-follow[data-reason=opted_out]")
    assert has_element?(view, "#enable-fediverse-link")
    refute has_element?(view, "#follow")
  end

  describe "the cached posts" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      %{conn: conn, user: user, account: account()}
    end

    test "public posts show to any signed-in member", %{conn: conn, account: acc} do
      p = cached_post(acc)

      {:ok, view, _html} = live(conn, ~p"/system/fediverse/account/#{acc.id}")

      assert has_element?(view, "[data-remote-post='#{p.id}']")
      refute has_element?(view, "#no-posts")
    end

    test "a followers-only post needs the viewer's own accepted follow", %{
      conn: conn,
      user: user,
      account: acc
    } do
      p = cached_post(acc, %{audience: "followers"})

      {:ok, view, _html} = live(conn, ~p"/system/fediverse/account/#{acc.id}")
      refute has_element?(view, "[data-remote-post='#{p.id}']")

      follow(user, acc)

      {:ok, view, _html} = live(conn, ~p"/system/fediverse/account/#{acc.id}")
      assert has_element?(view, "[data-remote-post='#{p.id}']")
    end

    test "a requested follow does not open them", %{conn: conn, user: user, account: acc} do
      p = cached_post(acc, %{audience: "followers"})
      follow(user, acc, "requested")

      {:ok, view, _html} = live(conn, ~p"/system/fediverse/account/#{acc.id}")

      refute has_element?(view, "[data-remote-post='#{p.id}']")
    end
  end

  describe "the entry points" do
    test "a remote post in the feed links to the account page", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      acc = account()
      follow(user, acc)
      cached_post(acc)

      {:ok, view, _html} = live(conn, ~p"/feed")

      assert has_element?(view, "[data-remote-account='#{acc.id}']")
    end
  end
end
