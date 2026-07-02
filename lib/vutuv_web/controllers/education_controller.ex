defmodule VutuvWeb.EducationController do
  use VutuvWeb, :controller

  import Ecto.Query

  alias Vutuv.Profiles.Education
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.SectionDocs
  alias VutuvWeb.ControllerHelpers

  plug(VutuvWeb.Plug.AuthUser when action not in [:index, :show])
  plug(:scrub_params, "education" when action in [:create, :update])

  plug(VutuvWeb.Plug.ResolveOwnedSlug,
    parent: :user,
    assoc: :educations,
    slug_param: "id",
    field: :slug,
    assign: :education,
    # imported entries can carry a NULL slug; their Phoenix.Param is the id
    id_fallback: true
  )

  # Index and show are also served as Markdown / text / JSON / XML via
  # VutuvWeb.AgentDocs.SectionDocs (keep the templates and the doc builder in
  # sync, see agent_docs_drift_test.exs).
  def index(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload(educations: from(e in Education) |> Education.order_by_date())

    AgentDocs.respond(conn,
      html: fn conn ->
        conn
        |> VutuvWeb.ViewAs.assign_preview()
        |> render("index.html", user: user, education: user.educations)
      end,
      doc: fn -> SectionDocs.build_index(user, :educations, user.educations) end
    )
  end

  def new(conn, _params) do
    changeset = Education.changeset(%Education{})
    render(conn, "new.html", changeset: changeset, current_year: current_year())
  end

  def create(conn, %{"education" => education_params}) do
    changeset =
      conn.assigns[:user]
      |> build_assoc(:educations)
      |> Education.changeset(education_params)

    ControllerHelpers.save(conn, Repo.insert(changeset),
      flash: gettext("Education created successfully."),
      redirect_to: ~p"/#{conn.assigns[:user]}/educations",
      render: "new.html",
      assigns: [current_year: current_year()]
    )
  end

  def show(conn, _params) do
    # ResolveOwnedSlug scopes :education to conn.assigns[:user], so no re-check.
    AgentDocs.respond(conn,
      html: &render(&1, "show.html", education: conn.assigns[:education]),
      doc: fn ->
        SectionDocs.build_show(conn.assigns[:user], :educations, conn.assigns[:education])
      end
    )
  end

  def edit(conn, _params) do
    education = conn.assigns[:education]
    changeset = Education.changeset(education)

    render(conn, "edit.html",
      education: education,
      changeset: changeset,
      current_year: current_year()
    )
  end

  def update(conn, %{"education" => education_params}) do
    education = conn.assigns[:education]
    changeset = Education.changeset(education, education_params)

    ControllerHelpers.save(conn, Repo.update(changeset),
      flash: gettext("Education updated successfully."),
      redirect_to: &~p"/#{conn.assigns[:user]}/educations/#{&1}",
      render: "edit.html",
      assigns: [education: education, current_year: current_year()]
    )
  end

  defp current_year, do: Date.utc_today().year

  def delete(conn, _params) do
    ControllerHelpers.delete(conn, conn.assigns[:education],
      flash: gettext("Education deleted successfully."),
      redirect_to: ~p"/#{conn.assigns[:user]}/educations"
    )
  end
end
