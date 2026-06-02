defmodule VutuvWeb.Api.WorkExperienceController do
  use VutuvWeb, :controller

  alias Vutuv.Profiles.WorkExperience

  def index(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload([:work_experiences])

    render(conn, "index.json", work_experiences: user.work_experiences)
  end

  # def create(conn, %{"work_experience" => work_experience_params}) do
  #   changeset = WorkExperience.changeset(%WorkExperience{}, work_experience_params)

  #   case Repo.insert(changeset) do
  #     {:ok, work_experience} ->
  #       conn
  #       |> put_status(:created)
  #       |> put_resp_header("location", api_user_work_experience_path(conn, :show, work_experience))
  #       |> render("show.json", work_experience: work_experience)
  #     {:error, changeset} ->
  #       conn
  #       |> put_status(:unprocessable_entity)
  #       |> render(Vutuv.ChangesetView, "error.json", changeset: changeset)
  #   end
  # end

  def show(conn, %{"id" => id}) do
    work_experience = Repo.get!(WorkExperience, id)
    render(conn, "show.json", work_experience: work_experience)
  end

  # def update(conn, %{"id" => id, "work_experience" => work_experience_params}) do
  #   work_experience = Repo.get!(WorkExperience, id)
  #   changeset = WorkExperience.changeset(work_experience, work_experience_params)

  #   case Repo.update(changeset) do
  #     {:ok, work_experience} ->
  #       render(conn, "show.json", work_experience: work_experience)
  #     {:error, changeset} ->
  #       conn
  #       |> put_status(:unprocessable_entity)
  #       |> render(Vutuv.ChangesetView, "error.json", changeset: changeset)
  #   end
  # end

  # def delete(conn, %{"id" => id}) do
  #   work_experience = Repo.get!(WorkExperience, id)

  #   # Here we use delete! (with a bang) because we expect
  #   # it to always work (and if it does not, it will raise).
  #   Repo.delete!(work_experience)

  #   send_resp(conn, :no_content, "")
  # end
end
