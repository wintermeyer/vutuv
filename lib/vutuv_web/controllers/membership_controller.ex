defmodule VutuvWeb.MembershipController do
  use VutuvWeb, :controller
  plug(VutuvWeb.Plug.RequireLoginOr404)
  plug(:assign_follow)

  alias Vutuv.Social.Follow
  alias VutuvWeb.ControllerHelpers

  plug(:scrub_params, "membership" when action in [:create])

  def create(conn, %{"membership" => membership_params}) do
    ControllerHelpers.save(
      conn,
      Vutuv.Social.create_membership(conn.assigns[:follow], membership_params),
      flash: gettext("Membership created successfully."),
      redirect_to: ~p"/follows/#{conn.assigns[:follow]}/memberships",
      render: "new.html"
    )
  end

  def delete(conn, %{"id" => id}) do
    # Scoped to the (ownership-checked) follow so a caller can only delete
    # memberships of a follow they actually own.
    membership = Vutuv.Social.get_membership!(conn.assigns[:follow], id)

    # Here we use delete! (with a bang) because we expect
    # it to always work (and if it does not, it will raise).
    Vutuv.Social.delete_membership!(membership)

    conn
    |> put_flash(:info, gettext("Membership deleted successfully."))
    |> redirect(to: ~p"/follows/#{conn.assigns[:follow]}/memberships")
  end

  defp assign_follow(conn, _opts) do
    current_user_id = conn.assigns.current_user_id

    case conn.params do
      %{"follow_id" => follow_id} ->
        case Repo.get(Follow, follow_id) do
          %Follow{follower_id: ^current_user_id} = follow ->
            assign(conn, :follow, follow)

          _ ->
            invalid_follow(conn)
        end

      _ ->
        invalid_follow(conn)
    end
  end

  defp invalid_follow(conn) do
    conn
    |> put_flash(:error, gettext("Invalid follow!"))
    |> redirect(to: ~p"/")
    |> halt
  end
end
