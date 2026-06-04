defmodule VutuvWeb.ConnectionController do
  use VutuvWeb, :controller

  alias Vutuv.Social.Connection
  alias VutuvWeb.ControllerHelpers

  plug(VutuvWeb.Plug.RequireLoginOr404)
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
    # The follower is always the session user, never trusted from params, so a
    # request cannot forge a follow edge on someone else's behalf. All follow
    # paths go through Social.follow/2, which also pushes the live
    # "started following you" notification to the followee (passing the loaded
    # struct saves it a Repo.get).
    case Vutuv.Social.follow(conn.assigns.current_user, connection_params["followee_id"]) do
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
end
