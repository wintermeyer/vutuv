defmodule VutuvWeb.PublicationController do
  use VutuvWeb, :controller

  alias Vutuv.Profiles.CvUpdates
  alias Vutuv.Profiles.Publication
  alias Vutuv.Social
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.SectionDocs
  alias VutuvWeb.ControllerHelpers

  plug(VutuvWeb.Plug.AuthUser when action not in [:index, :show])
  plug(:scrub_params, "publication" when action in [:create, :update])

  plug(VutuvWeb.Plug.ResolveOwnedSlug,
    parent: :user,
    assoc: :publications,
    slug_param: "id",
    field: :slug,
    assign: :publication,
    # imported entries can carry a NULL slug; their Phoenix.Param is the id
    id_fallback: true
  )

  # Index and show are also served as Markdown / text / JSON / XML via
  # VutuvWeb.AgentDocs.SectionDocs (keep the templates and the doc builder in
  # sync, see agent_docs_drift_test.exs).
  def index(conn, _params) do
    user = Repo.preload(conn.assigns[:user], publications: Publication.ordered())

    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "index.html",
          as_owner?: false,
          user: user,
          publications: user.publications,
          page_title: VutuvWeb.UserHelpers.member_page_title(user, gettext("Publications"))
        )
      end,
      doc: fn -> SectionDocs.build_index(user, :publications, user.publications) end
    )
  end

  # The owner's editor (GET /settings/publications).
  def manage(conn, _params) do
    user = Repo.preload(conn.assigns[:user], publications: Publication.ordered())

    render(conn, "manage.html",
      user: user,
      publications: user.publications,
      as_owner?: true,
      page_title: gettext("Publications")
    )
  end

  def new(conn, _params) do
    # The "tell my followers" box starts ticked (issue #980) — see
    # WorkExperienceController.new/2 for why. The data default stays false.
    changeset = Publication.changeset(%Publication{announce_to_followers?: true})

    render(conn, "new.html",
      changeset: changeset,
      followers: Social.follower_count(conn.assigns[:user])
    )
  end

  def create(conn, %{"publication" => publication_params}) do
    user = conn.assigns[:user]

    changeset =
      user
      |> build_assoc(:publications)
      |> Publication.changeset(publication_params)

    result = Repo.insert(changeset)
    with {:ok, publication} <- result, do: CvUpdates.announce(user, publication)

    ControllerHelpers.save(conn, result,
      flash: gettext("Publication added successfully."),
      redirect_to: ~p"/settings/publications",
      render: "new.html",
      assigns: [followers: Social.follower_count(user)]
    )
  end

  def show(conn, _params) do
    # ResolveOwnedSlug scopes :publication to conn.assigns[:user], so no re-check.
    publication = conn.assigns[:publication]

    AgentDocs.respond(conn,
      html:
        &render(&1, "show.html",
          publication: publication,
          page_title:
            VutuvWeb.UserHelpers.member_page_title(conn.assigns[:user], publication.title)
        ),
      doc: fn -> SectionDocs.build_show(conn.assigns[:user], :publications, publication) end
    )
  end

  def edit(conn, _params) do
    publication = conn.assigns[:publication]
    changeset = Publication.changeset(publication)
    render(conn, "edit.html", publication: publication, changeset: changeset)
  end

  def update(conn, %{"publication" => publication_params}) do
    publication = conn.assigns[:publication]
    changeset = Publication.changeset(publication, publication_params)

    ControllerHelpers.save(conn, Repo.update(changeset),
      flash: gettext("Publication updated successfully."),
      redirect_to: ~p"/settings/publications",
      render: "edit.html",
      assigns: [publication: publication]
    )
  end

  def delete(conn, _params) do
    ControllerHelpers.delete(conn, conn.assigns[:publication],
      flash: gettext("Publication deleted successfully."),
      redirect_to: ~p"/settings/publications"
    )
  end
end
