defmodule VutuvWeb.WorkExperienceController do
  use VutuvWeb, :controller

  alias Vutuv.Profiles.WorkExperience
  alias VutuvWeb.ControllerHelpers

  plug(VutuvWeb.Plug.AuthUser when action not in [:index, :show])
  plug(:scrub_params, "work_experience" when action in [:create, :update])

  plug(VutuvWeb.Plug.ResolveOwnedSlug,
    parent: :user,
    assoc: :work_experiences,
    slug_param: "id",
    field: :slug,
    assign: :job
  )

  def index(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload(
        work_experiences:
          from(u in Vutuv.Profiles.WorkExperience) |> WorkExperience.order_by_date()
      )

    render(conn, "index.html", user: user, work_experience: user.work_experiences)
  end

  def new(conn, _params) do
    changeset = WorkExperience.changeset(%WorkExperience{})
    render(conn, "new.html", changeset: changeset, current_year: current_year())
  end

  def create(conn, %{"work_experience" => work_experience_params}) do
    changeset =
      conn.assigns[:user]
      |> build_assoc(:work_experiences)
      |> WorkExperience.changeset(work_experience_params)

    ControllerHelpers.save(conn, Repo.insert(changeset),
      flash: gettext("Work experience created successfully."),
      redirect_to: ~p"/#{conn.assigns[:user]}/work_experiences",
      render: "new.html",
      assigns: [current_year: current_year()]
    )
  end

  def show(conn, _params) do
    work_experience =
      conn.assigns[:job]
      |> Repo.preload([:user])

    if work_experience.user.id == conn.assigns[:user].id do
      render(conn, "show.html", work_experience: work_experience)
    else
      redirect(conn,
        to: ~p"/#{work_experience.user}/work_experiences/#{work_experience}"
      )
    end
  end

  def edit(conn, _params) do
    work_experience = conn.assigns[:job]
    changeset = WorkExperience.changeset(work_experience)

    render(conn, "edit.html",
      work_experience: work_experience,
      changeset: changeset,
      current_year: current_year()
    )
  end

  def update(conn, %{"work_experience" => work_experience_params}) do
    work_experience = conn.assigns[:job]
    changeset = WorkExperience.changeset(work_experience, work_experience_params)

    ControllerHelpers.save(conn, Repo.update(changeset),
      flash: gettext("Work experience updated successfully."),
      redirect_to: &~p"/#{conn.assigns[:user]}/work_experiences/#{&1}",
      render: "edit.html",
      assigns: [work_experience: work_experience, current_year: current_year()]
    )
  end

  defp current_year, do: Date.utc_today().year

  def delete(conn, _params) do
    # Here we use delete! (with a bang) because we expect
    # it to always work (and if it does not, it will raise).
    Repo.delete!(conn.assigns[:job])

    conn
    |> put_flash(:info, gettext("Work experience deleted successfully."))
    |> redirect(to: ~p"/#{conn.assigns[:user]}/work_experiences")
  end
end
