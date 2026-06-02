defmodule VutuvWeb.ConnectionController do
  use VutuvWeb, :controller

  alias Vutuv.Social.Connection
  alias VutuvWeb.ControllerHelpers

  plug(:require_user_logged_in)
  plug(:scrub_params, "connection" when action in [:create, :update])

  def index(conn, _params) do
    connections =
      Repo.all(Connection)
      |> Repo.preload([:follower, :followee])

    render(conn, "index.html", connections: connections)
  end

  def new(conn, _params) do
    changeset = Connection.changeset(%Connection{})
    render(conn, "new.html", changeset: changeset)
  end

  def create(conn, %{"connection" => connection_params}) do
    # follower_id is set from the session user, never trusted from params,
    # so a request cannot forge a follow edge on someone else's behalf.
    changeset =
      %Connection{follower_id: conn.assigns.current_user_id}
      |> Connection.changeset(Map.delete(connection_params, "follower_id"))

    case Repo.insert(changeset) do
      {:ok, _connection} ->
        conn
        |> put_flash(:info, gettext("Connection created successfully."))
        |> redirect(to: referrer_url(conn))

      {:error, _changeset} ->
        conn
        |> put_flash(:error, gettext("Something went wrong"))
        |> redirect(to: referrer_url(conn))
    end
  end

  def show(conn, %{"id" => id}) do
    connection =
      Repo.get!(Connection, id)
      |> Repo.preload([:groups, :follower, :followee])

    render(conn, "show.html", connection: connection)
  end

  def delete(conn, %{"id" => id}) do
    # Scope the lookup to the current user so a caller can only delete
    # their own follow edges, never an arbitrary connection by id.
    connection = Repo.get_by!(Connection, id: id, follower_id: conn.assigns.current_user_id)

    # Here we use delete! (with a bang) because we expect
    # it to always work (and if it does not, it will raise).
    Repo.delete!(connection)

    conn
    |> put_flash(:info, gettext("Connection deleted successfully."))
    |> redirect(to: referrer_url(conn))
  end

  # Fall back to the logged-in user's profile. This controller never assigns
  # :user, so the old `conn.assigns[:user]` fallback was always nil and raised
  # when interpolated into the route on a refererless request.
  defp referrer_url(conn) do
    ControllerHelpers.referrer_url(conn, fallback_url(conn.assigns[:current_user]))
  end

  defp fallback_url(%Vutuv.Accounts.User{} = user), do: ~p"/users/#{user}"
  defp fallback_url(_), do: ~p"/"

  defp require_user_logged_in(conn, _opts) do
    case conn.assigns[:current_user_id] do
      nil ->
        conn
        |> put_status(404)
        |> put_view(html: VutuvWeb.ErrorHTML)
        |> render("404.html")
        |> halt()

      _id ->
        conn
    end
  end
end
