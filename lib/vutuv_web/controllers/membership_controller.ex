defmodule VutuvWeb.MembershipController do
  use VutuvWeb, :controller
  plug(VutuvWeb.Plug.RequireLoginOr404)
  plug(:assign_connection)

  alias Vutuv.Social.Connection
  alias VutuvWeb.ControllerHelpers

  plug(:scrub_params, "membership" when action in [:create])

  def create(conn, %{"membership" => membership_params}) do
    ControllerHelpers.save(
      conn,
      Vutuv.Social.create_membership(conn.assigns[:connection], membership_params),
      flash: gettext("Membership created successfully."),
      redirect_to: ~p"/connections/#{conn.assigns[:connection]}/memberships",
      render: "new.html"
    )
  end

  def delete(conn, %{"id" => id}) do
    # Scoped to the (ownership-checked) connection so a caller can only delete
    # memberships of a connection they actually own.
    membership = Vutuv.Social.get_membership!(conn.assigns[:connection], id)

    # Here we use delete! (with a bang) because we expect
    # it to always work (and if it does not, it will raise).
    Vutuv.Social.delete_membership!(membership)

    conn
    |> put_flash(:info, gettext("Membership deleted successfully."))
    |> redirect(to: ~p"/connections/#{conn.assigns[:connection]}/memberships")
  end

  defp assign_connection(conn, _opts) do
    current_user_id = conn.assigns.current_user_id

    case conn.params do
      %{"connection_id" => connection_id} ->
        case Repo.get(Connection, connection_id) do
          %Connection{follower_id: ^current_user_id} = connection ->
            assign(conn, :connection, connection)

          _ ->
            invalid_connection(conn)
        end

      _ ->
        invalid_connection(conn)
    end
  end

  defp invalid_connection(conn) do
    conn
    |> put_flash(:error, gettext("Invalid connection!"))
    |> redirect(to: ~p"/")
    |> halt
  end
end
