defmodule VutuvWeb.Admin.AdminFediverseCardTest do
  @moduledoc """
  The admin dashboard's "Fediverse" card (issue #843, Part 2): the operator's
  one glance at outbound federation — how many members federate, how many
  remote followers exist and whether the delivery queue is healthy.
  """
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Delivery

  defp admin_dashboard(conn) do
    {conn, _admin} = create_and_login_admin(conn)
    get(conn, ~p"/admin")
  end

  test "surfaces the federation counts", %{conn: conn} do
    member = insert(:activated_user, fediverse_followers?: true)

    {:ok, _} =
      Fediverse.add_follower(member, %{
        actor_uri: "https://social.example/users/alice",
        inbox_uri: "https://social.example/inbox"
      })

    html = conn |> admin_dashboard() |> html_response(200)

    assert html =~ "Fediverse"
    assert html =~ ~s(id="admin-fediverse-link")
  end

  test "flags attention when deliveries are stuck", %{conn: conn} do
    member = insert(:activated_user, fediverse_followers?: true)

    Repo.insert!(%Delivery{
      user_id: member.id,
      inbox_uri: "https://social.example/inbox",
      activity_json: "{}",
      attempts: 5,
      next_attempt_at: DateTime.utc_now(:second),
      last_error: "HTTP 500"
    })

    assert Fediverse.stats().stuck_deliveries == 1

    html = conn |> admin_dashboard() |> html_response(200)
    assert html =~ ~s(id="admin-fediverse-link")
  end

  test "hides the card on an installation with federation switched off", %{conn: conn} do
    Application.put_env(:vutuv, :fediverse_enabled, false)
    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_enabled) end)

    html = conn |> admin_dashboard() |> html_response(200)
    refute html =~ ~s(id="admin-fediverse-link")
  end
end
