defmodule VutuvWeb.QualificationController do
  use VutuvWeb, :controller

  alias Vutuv.Profiles.CvUpdates
  alias Vutuv.Profiles.Qualification
  alias Vutuv.Social
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.SectionDocs
  alias VutuvWeb.ControllerHelpers

  plug(VutuvWeb.Plug.AuthUser when action not in [:index, :show])
  plug(:scrub_params, "qualification" when action in [:create, :update])
  # Certificates & licenses are keyed by their UUID, not a slug (a credential
  # name is neither unique nor URL-safe), so ResolveOwnedSlug's slug matching
  # doesn't apply — this owner-scoped resolver safely casts the id instead.
  plug(:resolve_qualification when action in [:show, :edit, :update, :delete])

  # Index and show are also served as Markdown / text / JSON / XML via
  # VutuvWeb.AgentDocs.SectionDocs (keep the templates and the doc builder in
  # sync, see agent_docs_drift_test.exs). Both show the anonymous public view,
  # which hides expired credentials (issue #859).
  def index(conn, _params) do
    user =
      Repo.preload(conn.assigns[:user],
        qualifications: Qualification.visible_to(false) |> Qualification.ordered()
      )

    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "index.html",
          as_owner?: false,
          user: user,
          qualifications: user.qualifications,
          page_title:
            VutuvWeb.UserHelpers.member_page_title(user, gettext("Certificates & licenses"))
        )
      end,
      doc: fn -> SectionDocs.build_index(user, :qualifications, user.qualifications) end
    )
  end

  # The owner's editor (GET /settings/qualifications) — shows everything the
  # member holds, expired entries included, since this is where they manage them.
  def manage(conn, _params) do
    user = Repo.preload(conn.assigns[:user], qualifications: Qualification.ordered())

    render(conn, "manage.html",
      user: user,
      qualifications: user.qualifications,
      as_owner?: true,
      page_title: gettext("Certificates & licenses")
    )
  end

  def new(conn, _params) do
    # The "tell my followers" box starts ticked (issue #980) — see
    # WorkExperienceController.new/2 for why. The data default stays false.
    changeset = Qualification.changeset(%Qualification{announce_to_followers?: true})

    render(conn, "new.html",
      changeset: changeset,
      followers: Social.follower_count(conn.assigns[:user])
    )
  end

  def create(conn, %{"qualification" => qualification_params}) do
    user = conn.assigns[:user]

    changeset =
      user
      |> build_assoc(:qualifications)
      |> Qualification.changeset(qualification_params)

    result = Repo.insert(changeset)
    with {:ok, qualification} <- result, do: CvUpdates.announce(user, qualification)

    ControllerHelpers.save(conn, result,
      flash: gettext("Certificate or license added successfully."),
      redirect_to: ~p"/settings/qualifications",
      render: "new.html",
      assigns: [followers: Social.follower_count(user)]
    )
  end

  def show(conn, _params) do
    # resolve_qualification scoped :qualification to conn.assigns[:user].
    AgentDocs.respond(conn,
      html:
        &render(&1, "show.html",
          qualification: conn.assigns[:qualification],
          page_title: entry_page_title(conn.assigns[:user], conn.assigns[:qualification])
        ),
      doc: fn ->
        SectionDocs.build_show(conn.assigns[:user], :qualifications, conn.assigns[:qualification])
      end
    )
  end

  defp entry_page_title(user, qualification) do
    label =
      if qualification.name in [nil, ""],
        do: gettext("Certificates & licenses"),
        else: qualification.name

    VutuvWeb.UserHelpers.member_page_title(user, label)
  end

  def edit(conn, _params) do
    qualification = conn.assigns[:qualification]
    changeset = Qualification.changeset(qualification)
    render(conn, "edit.html", qualification: qualification, changeset: changeset)
  end

  def update(conn, %{"qualification" => qualification_params}) do
    qualification = conn.assigns[:qualification]
    changeset = Qualification.changeset(qualification, qualification_params)

    ControllerHelpers.save(conn, Repo.update(changeset),
      flash: gettext("Certificate or license updated successfully."),
      redirect_to: ~p"/settings/qualifications",
      render: "edit.html",
      assigns: [qualification: qualification]
    )
  end

  def delete(conn, _params) do
    ControllerHelpers.delete(conn, conn.assigns[:qualification],
      flash: gettext("Certificate or license deleted successfully."),
      redirect_to: ~p"/settings/qualifications"
    )
  end

  # Owner-scoped lookup by UUID: a bad or foreign id renders a clean 404 instead
  # of raising a cast error. Scopes through conn.assigns[:user] — the profile
  # owner for the public show, the current user for the /settings actions.
  defp resolve_qualification(conn, _opts) do
    case ControllerHelpers.get_owned(conn.assigns[:user], :qualifications, conn.params["id"]) do
      %Qualification{} = qualification -> assign(conn, :qualification, qualification)
      nil -> conn |> ControllerHelpers.render_error(404) |> halt()
    end
  end
end
