defmodule VutuvWeb.Api.FolloweeController do
  use VutuvWeb, :controller

  # alias Vutuv.Followee

  def index(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload([:followees])

    render(conn, "index.json", followees: user.followees)
  end

  # def create(conn, %{"followee" => followee_params}) do
  #   changeset = Followee.changeset(%Followee{}, followee_params)

  #   case Repo.insert(changeset) do
  #     {:ok, followee} ->
  #       conn
  #       |> put_status(:created)
  #       |> put_resp_header("location", followee_path(conn, :show, followee))
  #       |> render("show.json", followee: followee)
  #     {:error, changeset} ->
  #       conn
  #       |> put_status(:unprocessable_entity)
  #       |> render(Vutuv.ChangesetView, "error.json", changeset: changeset)
  #   end
  # end

  # def update(conn, %{"id" => id, "followee" => followee_params}) do
  #   followee = Repo.get!(Followee, id)
  #   changeset = Followee.changeset(followee, followee_params)

  #   case Repo.update(changeset) do
  #     {:ok, followee} ->
  #       render(conn, "show.json", followee: followee)
  #     {:error, changeset} ->
  #       conn
  #       |> put_status(:unprocessable_entity)
  #       |> render(Vutuv.ChangesetView, "error.json", changeset: changeset)
  #   end
  # end

  # def delete(conn, %{"id" => id}) do
  #   followee = Repo.get!(Followee, id)

  #   # Here we use delete! (with a bang) because we expect
  #   # it to always work (and if it does not, it will raise).
  #   Repo.delete!(followee)

  #   send_resp(conn, :no_content, "")
  # end
end
