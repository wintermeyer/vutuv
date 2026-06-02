defmodule VutuvWeb.GroupController do
  use VutuvWeb, :controller
  alias Vutuv.Social.Group

  plug(VutuvWeb.Plug.AuthUser)
  plug(:scrub_params, "group" when action in [:create, :update])

  def index(conn, _params) do
    user =
      Repo.get!(Vutuv.Accounts.User, conn.assigns[:user].id)
      |> Repo.preload([:groups])

    render(conn, "index.html", groups: user.groups)
  end

  def new(conn, _params) do
    changeset = Group.changeset(%Group{})
    render(conn, "new.html", changeset: changeset)
  end

  def create(conn, %{"group" => group_params}) do
    changeset =
      conn.assigns[:user]
      |> build_assoc(:groups)
      |> Group.changeset(group_params)

    case Repo.insert(changeset) do
      {:ok, _group} ->
        conn
        |> put_flash(:info, gettext("Group created successfully."))
        |> redirect(to: ~p"/users/#{conn.assigns[:user]}/groups")

      {:error, changeset} ->
        render(conn, "new.html", changeset: changeset)
    end
  end

  def show(conn, %{"id" => id}) do
    group = Repo.get!(assoc(conn.assigns[:user], :groups), id)
    render(conn, "show.html", group: group)
  end

  def edit(conn, %{"id" => id}) do
    group = Repo.get!(assoc(conn.assigns[:user], :groups), id)
    changeset = Group.changeset(group)
    render(conn, "edit.html", group: group, changeset: changeset)
  end

  def update(conn, %{"id" => id, "group" => group_params}) do
    group = Repo.get!(assoc(conn.assigns[:user], :groups), id)
    changeset = Group.changeset(group, group_params)

    case Repo.update(changeset) do
      {:ok, group} ->
        conn
        |> put_flash(:info, gettext("Group updated successfully."))
        |> redirect(to: ~p"/users/#{conn.assigns[:user]}/groups/#{group}")

      {:error, changeset} ->
        render(conn, "edit.html", group: group, changeset: changeset)
    end
  end

  def delete(conn, %{"id" => id}) do
    group = Repo.get!(assoc(conn.assigns[:user], :groups), id)

    # Here we use delete! (with a bang) because we expect
    # it to always work (and if it does not, it will raise).
    Repo.delete!(group)

    conn
    |> put_flash(:info, gettext("Group deleted successfully."))
    |> redirect(to: ~p"/users/#{conn.assigns[:user]}/groups")
  end
end
