defmodule VutuvWeb.WorkExperienceController do
  use VutuvWeb, :controller

  alias Vutuv.Accounts
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
        render(conn, "index.html",
          as_owner?: false,
          user: user,
          work_experience: user.work_experiences,
          # The pinned profile job title (issue #833), so the management list can
          # mark it and offer the chooser. Nil = automatic heuristic.
          profile_work_experience_id: user.profile_work_experience_id
        )
      end,
      doc: fn -> SectionDocs.build_index(user, :work_experiences, user.work_experiences) end
    )
  end

  # The owner's editor (GET /settings/work_experiences), including the
  # profile-job-title pin chooser (issue #833).
  def manage(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload(
        work_experiences:
          from(u in Vutuv.Profiles.WorkExperience) |> WorkExperience.order_by_date()
      )

    render(conn, "manage.html",
      user: user,
      work_experience: user.work_experiences,
      profile_work_experience_id: user.profile_work_experience_id,
      as_owner?: true,
      page_title: gettext("Experience")
    )
  end

  # Pin one work experience as the member's profile job title, or clear the
  # pin back to the automatic heuristic (issue #833). Owner-only (AuthUser) and
  # owner-scoped (ResolveOwnedSlug assigns :job from the member's own rows), so
  # a member can only ever pin their own role.
  def pin(conn, _params) do
    user = conn.assigns[:user]

    case Accounts.pin_profile_work_experience(user, conn.assigns[:job]) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, gettext("This job title now shows at the top of your profile."))
        |> redirect(to: ~p"/settings/work_experiences")

      {:error, _} ->
        conn
        |> put_flash(:error, gettext("That work experience could not be pinned."))
        |> redirect(to: ~p"/settings/work_experiences")
    end
  end

  def unpin(conn, _params) do
    user = conn.assigns[:user]
    {:ok, _user} = Accounts.unpin_profile_work_experience(user)

    conn
    |> put_flash(
      :info,
      gettext("The job title at the top of your profile is chosen automatically again.")
    )
    |> redirect(to: ~p"/settings/work_experiences")
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
      redirect_to: ~p"/settings/work_experiences",
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
      redirect_to: fn _entry -> ~p"/settings/work_experiences" end,
      render: "edit.html",
      assigns: [work_experience: work_experience, current_year: current_year()]
    )
  end

  defp current_year, do: Date.utc_today().year

  def delete(conn, _params) do
    ControllerHelpers.delete(conn, conn.assigns[:job],
      flash: gettext("Work experience deleted successfully."),
      redirect_to: ~p"/settings/work_experiences"
    )
  end
end
