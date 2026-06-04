defmodule VutuvWeb.Api.WorkExperienceController do
  use VutuvWeb, :controller
  alias VutuvWeb.ControllerHelpers

  def index(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload([:work_experiences])

    render(conn, "index.json", work_experiences: user.work_experiences)
  end

  def show(conn, %{"id" => id}) do
    work_experience = ControllerHelpers.get_owned!(conn, :work_experiences, id)
    render(conn, "show.json", work_experience: work_experience)
  end
end
