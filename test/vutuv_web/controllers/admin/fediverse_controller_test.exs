defmodule VutuvWeb.Admin.FediverseControllerTest do
  @moduledoc """
  The operator's Fediverse screen (`/admin/fediverse`, issue #1067): block a
  remote server, see what each server stores here, lift a block.

  async: false — the tests flip `:fediverse_enabled`, an application-env switch
  the SQL sandbox does not roll back.
  """
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follower

  defp login_admin(conn) do
    {conn, admin} = create_and_login_admin(conn)
    {conn, admin}
  end

  test "lists the blocked servers and the inbound volume", %{conn: conn} do
    {conn, admin} = login_admin(conn)
    member = insert(:activated_user, fediverse_followers?: true)

    {:ok, _} =
      Fediverse.add_follower(member, %{
        actor_uri: "https://social.example/users/alice",
        inbox_uri: "https://social.example/inbox"
      })

    {:ok, {blocked, _}} =
      Fediverse.block_instance(%{"host" => "spam.example", "reason" => "bots"}, admin)

    html = conn |> get(~p"/admin/fediverse") |> html_response(200)

    assert html =~ ~s(data-blocked-host="spam.example")
    assert html =~ "bots"
    assert html =~ ~s(data-inbound-host="social.example")
    # The rendered form/unblock targets, not a route we know exists: a hand-built
    # path in a test would not catch a form posting somewhere retired.
    assert html =~ ~s(action="/admin/fediverse")
    assert html =~ ~s(href="/admin/fediverse/#{blocked.id}")
  end

  test "blocking a server purges what it already stored", %{conn: conn} do
    {conn, _admin} = login_admin(conn)
    member = insert(:activated_user, fediverse_followers?: true)

    {:ok, _} =
      Fediverse.add_follower(member, %{
        actor_uri: "https://spam.example/users/bot",
        inbox_uri: "https://spam.example/inbox"
      })

    conn = post(conn, ~p"/admin/fediverse", blocked_instance: %{host: "https://spam.example/"})

    assert redirected_to(conn) == ~p"/admin/fediverse"
    assert Fediverse.instance_blocked?("https://spam.example/users/bot")
    assert Repo.aggregate(Follower, :count) == 0
  end

  test "a malformed server name is refused with a flash, not a 500", %{conn: conn} do
    {conn, _admin} = login_admin(conn)

    conn = post(conn, ~p"/admin/fediverse", blocked_instance: %{host: "not a host"})

    assert redirected_to(conn) == ~p"/admin/fediverse"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "mastodon.example"
    assert Fediverse.blocked_instance_count() == 0
  end

  test "unblocking removes the row without resurrecting anything", %{conn: conn} do
    {conn, admin} = login_admin(conn)
    {:ok, {blocked, _}} = Fediverse.block_instance(%{"host" => "spam.example"}, admin)

    conn = delete(conn, ~p"/admin/fediverse/#{blocked.id}")

    assert redirected_to(conn) == ~p"/admin/fediverse"
    assert Fediverse.blocked_instance_count() == 0
  end

  test "the page 404s on an installation with federation switched off", %{conn: conn} do
    {conn, _admin} = login_admin(conn)
    Application.put_env(:vutuv, :fediverse_enabled, false)
    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_enabled) end)

    assert conn |> get(~p"/admin/fediverse") |> html_response(404)
  end

  test "a non-admin cannot reach it", %{conn: conn} do
    {conn, _user} = create_and_login_user(conn)

    assert conn |> get(~p"/admin/fediverse") |> html_response(403)
  end
end
