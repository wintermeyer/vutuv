defmodule VutuvWeb.SettingsMutesTest do
  use VutuvWeb.ConnCase, async: true

  # `/settings/mutes`: the page a member goes to when they want to
  # know who they silenced months ago, and the two write routes every card's ⋯
  # menu posts to. Muting happens on a card; this is its back side, and without
  # one a mute placed on an account nobody follows is unfindable — the following
  # list does not show it, because there is no follow.

  import Vutuv.MastodonHelpers, only: [remote_account: 1]

  alias Vutuv.Fediverse
  alias Vutuv.Mutes
  alias Vutuv.Social

  # The shared helper, for its unique `actor_uri`: a literal one in an
  # `async: true` file convoys on the unique index with every other file
  # spelling the same address.
  defp account(handle), do: remote_account(handle: handle, name: String.capitalize(handle))

  test "the page lists both stores and offers a way back", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    lilly = account("lilly")
    stranger = insert(:activated_user)
    {:ok, _} = Mutes.mute(user, lilly, :reposts)
    {:ok, _} = Mutes.mute(user, stranger, :all)

    html = conn |> get(~p"/settings/mutes") |> html_response(200)

    assert html =~ "@lilly@"
    assert html =~ stranger.username
    assert html =~ ~s(data-account-mute="remote_account")
    assert html =~ ~s(data-mute-scope="reposts")
  end

  test "with nothing muted the page says so and points at the word filters", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    html = conn |> get(~p"/settings/mutes") |> html_response(200)

    assert html =~ ~s(href="#{~p"/settings/filters"}")
    assert html =~ ~s(id="account-mute-list")
  end

  test "a card's Mute posts here and comes back to the page it was pressed on", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    lilly = account("lilly")

    conn =
      post(conn, ~p"/settings/mutes", %{
        "kind" => "remote_account",
        "id" => lilly.id,
        "return_to" => "/feed"
      })

    assert redirected_to(conn) == "/feed"
    assert Mutes.scope_for(user, lilly) == :all
  end

  test "the repost scope is what the boost banner's item sends", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    doris = account("doris")

    conn =
      post(conn, ~p"/settings/mutes", %{
        "kind" => "remote_account",
        "id" => doris.id,
        "scope" => "reposts"
      })

    assert redirected_to(conn) == ~p"/settings/mutes"
    assert Mutes.scope_for(user, doris) == :reposts
  end

  test "unmuting lifts a follow's own mute too", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    followee = insert(:activated_user)
    {:ok, _} = Social.follow(user, followee.id)
    {:ok, _} = Social.set_follow_mute(user, followee, true)

    assert Mutes.scope_for(user, followee) == :all

    conn = delete(conn, ~p"/settings/mutes", %{"kind" => "member", "id" => followee.id})

    assert redirected_to(conn) == ~p"/settings/mutes"
    assert Mutes.scope_for(user, followee) == nil
  end

  test "an id that resolves to nothing is a no-op, not a crash", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    conn =
      post(conn, ~p"/settings/mutes", %{
        "kind" => "remote_account",
        "id" => Vutuv.UUIDv7.generate()
      })

    assert redirected_to(conn) == ~p"/settings/mutes"
  end

  test "a foreign return_to is refused, so a mute cannot carry somebody off-site", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)
    doris = account("doris")

    conn =
      post(conn, ~p"/settings/mutes", %{
        "kind" => "remote_account",
        "id" => doris.id,
        "return_to" => "https://evil.example/"
      })

    assert redirected_to(conn) == ~p"/settings/mutes"
  end

  test "the settings hub and sidebar carry the row", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    html = conn |> get(~p"/settings") |> html_response(200)

    assert html =~ ~s(href="#{~p"/settings/mutes"}")
    assert html =~ ~s(href="#{~p"/settings/filters"}")
  end

  test "a mute of a followed remote account sets the follow flag the account page reads", %{
    conn: conn
  } do
    {conn, user} = create_and_login_user(conn)
    doris = account("doris")

    {:ok, _follow} =
      %Fediverse.Follow{
        user_id: user.id,
        remote_account_id: doris.id,
        state: "accepted",
        follow_activity_id: "https://vutuv.test/#{user.id}/actor#f/#{doris.id}"
      }
      |> Repo.insert()

    post(conn, ~p"/settings/mutes", %{"kind" => "remote_account", "id" => doris.id})

    assert Repo.get_by!(Fediverse.Follow, user_id: user.id, remote_account_id: doris.id).muted
  end
end
