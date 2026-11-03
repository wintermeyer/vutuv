defmodule VutuvWeb.PublicationController do
  use VutuvWeb, :controller

  alias Vutuv.Profiles.CvUpdates
  alias Vutuv.Profiles.OrcidImport
  alias Vutuv.Profiles.Publication
  alias Vutuv.Social
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.SectionDocs
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.RateLimit

  plug(VutuvWeb.Plug.AuthUser when action not in [:index, :show])
  plug(:scrub_params, "publication" when action in [:create, :update])
  # After AuthUser, so a stranger 403s and is never counted. Each preview is
  # up to three requests this server sends to the ORCID public API.
  plug(:rate_limit_orcid when action in [:orcid_import, :orcid_apply])

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
      # What the ORCID import card may offer (issue #2383): the button, a
      # hint to list an iD first, or nothing on an installation with it off.
      orcid_import: OrcidImport.offer(user),
      page_title: gettext("Publications")
    )
  end

  # The ORCID import preview (issue #2383): the record's works with a box
  # each, nothing written yet. Every way the fetch can fail lands the member
  # back on the editor with one sentence saying what to do.
  def orcid_import(conn, _params) do
    user = conn.assigns[:user]

    case OrcidImport.candidates(user) do
      {:ok, candidates} ->
        render(conn, "orcid_import.html",
          candidates: candidates,
          payload: Jason.encode!(OrcidImport.payload_map(candidates)),
          page_title: gettext("Import from ORCID")
        )

      {:error, :no_account} ->
        conn
        |> put_flash(
          :info,
          gettext("Add your ORCID iD to your profile first, then import from it.")
        )
        |> redirect(to: ~p"/settings/social_media_accounts/new")

      {:error, :disabled} ->
        conn
        |> put_flash(:error, gettext("Importing from ORCID is disabled on this installation."))
        |> redirect(to: ~p"/settings/publications")

      {:error, :gone} ->
        conn
        |> put_flash(
          :error,
          gettext(
            "ORCID knows no public record under this iD. Please check the iD on your profile."
          )
        )
        |> redirect(to: ~p"/settings/publications")

      {:error, :transient} ->
        conn
        |> put_flash(:error, gettext("ORCID did not answer. Please try again in a moment."))
        |> redirect(to: ~p"/settings/publications")
    end
  end

  def orcid_apply(conn, %{"payload" => payload} = params) do
    user = conn.assigns[:user]
    selected = Map.get(params, "selected", [])

    with {:ok, decoded} <- Jason.decode(payload),
         selection = OrcidImport.selection_from_payload(decoded, selected),
         {:ok, tally} <- OrcidImport.apply_selection(user, selection) do
      # Which import ran, never what came in — the entries are on the profile.
      Vutuv.AccountEvents.record(user, "import_applied", conn: conn, details: %{source: "orcid"})

      conn
      |> put_flash(:info, orcid_import_flash(tally))
      |> redirect(to: ~p"/settings/publications")
    else
      _ ->
        conn
        |> put_flash(:error, gettext("The import could not be completed. Please try again."))
        |> redirect(to: ~p"/settings/publications")
    end
  end

  def orcid_apply(conn, _params) do
    conn
    |> put_flash(:error, gettext("The import could not be completed. Please try again."))
    |> redirect(to: ~p"/settings/publications")
  end

  defp orcid_import_flash(%{created: 0, skipped: skipped}) when skipped > 0,
    do: gettext("Nothing new to import: every selected publication was already on your profile.")

  defp orcid_import_flash(%{created: created}) do
    ngettext(
      "%{count} publication imported from ORCID.",
      "%{count} publications imported from ORCID.",
      created
    )
  end

  defp rate_limit_orcid(conn, _opts) do
    case RateLimit.check_orcid_import(conn, conn.assigns[:user]) do
      :ok ->
        conn

      :rate_limited ->
        conn
        |> put_flash(:error, gettext("Too many imports. Please try again in a little while."))
        |> redirect(to: ~p"/settings/publications")
        |> halt()
    end
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
