defmodule VutuvWeb.Api.GroupController do
  use VutuvWeb, :controller

  alias Vutuv.Social.Group

  def index(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload([:groups])

    render(conn, "index.json", groups: user.groups)
  end

  # def create(conn, %{"group" => group_params}) do
  #   changeset = Group.changeset(%Group{}, group_params)

  #   case Repo.insert(changeset) do
  #     {:ok, group} ->
  #       conn
  #       |> put_status(:created)
  #       |> put_resp_header("location", group_path(conn, :show, group))
  #       |> render("show.json", group: group)
  #     {:error, changeset} ->
  #       conn
  #       |> put_status(:unprocessable_entity)
  #       |> render(Vutuv.ChangesetView, "error.json", changeset: changeset)
  #   end
  # end

  def show(conn, %{"id" => id}) do
    group = Repo.get!(Group, id)
    render(conn, "show.json", group: group)
  end

  # def update(conn, %{"id" => id, "group" => group_params}) do
  #   group = Repo.get!(Group, id)
  #   changeset = Group.changeset(group, group_params)

  #   case Repo.update(changeset) do
  #     {:ok, group} ->
  #       render(conn, "show.json", group: group)
  #     {:error, changeset} ->
  #       conn
  #       |> put_status(:unprocessable_entity)
  #       |> render(Vutuv.ChangesetView, "error.json", changeset: changeset)
  #   end
  # end

  # def delete(conn, %{"id" => id}) do
  #   group = Repo.get!(Group, id)

  #   # Here we use delete! (with a bang) because we expect
  #   # it to always work (and if it does not, it will raise).
  #   Repo.delete!(group)

  #   send_resp(conn, :no_content, "")
  # end
end
