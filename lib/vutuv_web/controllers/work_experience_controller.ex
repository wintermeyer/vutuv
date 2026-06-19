defmodule VutuvWeb.WorkExperienceController do
  use VutuvWeb, :controller

  alias Vutuv.Profiles.WorkExperience
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.SectionDocs
  alias VutuvWeb.ControllerHelpers

  plug(VutuvWeb.Plug.AuthUser when action not in [:index, :show])
  plug(:scrub_params, "work_experience" when action in [:create, :update])

  plug(VutuvWeb.Plug.ResolveOwnedSlug,
    parent: :user,
    assoc: :work_experiences,
    slug_param: "id",
    field: :slug,
    assign: :job,
    # legacy imports can carry a NULL slug; their Phoenix.Param is the id
    id_fallback: true
  )

  # Index and show are also served as Markdown / text / JSON via
  # VutuvWeb.AgentDocs.SectionDocs (keep the templates and the doc builder
  # in sync, see agent_docs_drift_test.exs).
  def index(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload(
        work_experiences:
          from(u in Vutuv.Profiles.WorkExperience) |> WorkExperience.order_by_date()
      )

    AgentDocs.respond(conn,
      html: fn conn ->
        conn
        |> VutuvWeb.ViewAs.assign_preview()
        |> render("index.html", user: user, work_experience: user.work_experiences)
      end,
      doc: fn -> SectionDocs.build_index(user, :work_experiences, user.work_experiences) end
    )
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
    # ResolveOwnedSlug scopes :job to conn.assigns[:user], so no ownership re-check.
    AgentDocs.respond(conn,
      html: &render(&1, "show.html", work_experience: conn.assigns[:job]),
      doc: fn ->
        SectionDocs.build_show(conn.assigns[:user], :work_experiences, conn.assigns[:job])
      end
    )
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
