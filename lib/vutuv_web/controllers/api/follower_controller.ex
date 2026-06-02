defmodule VutuvWeb.Api.FollowerController do
  use VutuvWeb, :controller

  # alias Vutuv.Follower

  def index(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload([:followers])

    render(conn, "index.json", followers: user.followers)
  end

  # def create(conn, %{"follower" => follower_params}) do
  #   changeset = Follower.changeset(%Follower{}, follower_params)

  #   case Repo.insert(changeset) do
  #     {:ok, follower} ->
  #       conn
  #       |> put_status(:created)
  #       |> put_resp_header("location", follower_path(conn, :show, follower))
  #       |> render("show.json", follower: follower)
  #     {:error, changeset} ->
  #       conn
  #       |> put_status(:unprocessable_entity)
  #       |> render(Vutuv.ChangesetView, "error.json", changeset: changeset)
  #   end
  # end

  # def update(conn, %{"id" => id, "follower" => follower_params}) do
  #   follower = Repo.get!(Follower, id)
  #   changeset = Follower.changeset(follower, follower_params)

  #   case Repo.update(changeset) do
  #     {:ok, follower} ->
  #       render(conn, "show.json", follower: follower)
  #     {:error, changeset} ->
  #       conn
  #       |> put_status(:unprocessable_entity)
  #       |> render(Vutuv.ChangesetView, "error.json", changeset: changeset)
  #   end
  # end

  # def delete(conn, %{"id" => id}) do
  #   follower = Repo.get!(Follower, id)

  #   # Here we use delete! (with a bang) because we expect
  #   # it to always work (and if it does not, it will raise).
  #   Repo.delete!(follower)

  #   send_resp(conn, :no_content, "")
  # end
end
