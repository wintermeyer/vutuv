defmodule VutuvWeb.QualificationController do
  use VutuvWeb, :controller

  require Logger

  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Profiles.CvUpdates
  alias Vutuv.Profiles.Qualification
  alias Vutuv.QualificationDocument
  alias Vutuv.Social
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.SectionDocs
  alias VutuvWeb.ControllerHelpers

  plug(VutuvWeb.Plug.AuthUser when action not in [:index, :show])
  plug(:scrub_params, "qualification" when action in [:create, :update])
  # Certificates & licenses are keyed by their UUID, not a slug (a credential
  # name is neither unique nor URL-safe), so ResolveOwnedSlug's slug matching
  # doesn't apply — this owner-scoped resolver safely casts the id instead.
  plug(
    :resolve_qualification
    when action in [:show, :edit, :update, :delete, :delete_document]
  )

  # Index and show are also served as Markdown / text / JSON / XML via
  # VutuvWeb.AgentDocs.SectionDocs (keep the templates and the doc builder in
  # sync, see agent_docs_drift_test.exs). Both show the anonymous public view,
  # which hides expired credentials (issue #859).
  def index(conn, _params) do
    # citing_jobs_preload: the jobs earned with each credential ride along for
    # the usage badges (issue #1005).
    user =
      Repo.preload(conn.assigns[:user],
        qualifications:
          {Qualification.visible_to(false) |> Qualification.ordered(),
           Qualification.citing_jobs_preload()}
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
    user =
      Repo.preload(conn.assigns[:user],
        qualifications: {Qualification.ordered(), Qualification.citing_jobs_preload()}
      )

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

    with {:ok, qualification} <- result do
      store_document(qualification, qualification_params)
      CvUpdates.announce(user, qualification)
    end

    ControllerHelpers.save(conn, result,
      flash: gettext("Certificate or license added successfully."),
      redirect_to: ~p"/settings/qualifications",
      render: "new.html",
      assigns: [followers: Social.follower_count(user)]
    )
  end

  def show(conn, _params) do
    # resolve_qualification scoped :qualification to conn.assigns[:user]; the
    # citing jobs ride along for the usage line (issue #1005).
    qualification =
      Repo.preload(conn.assigns[:qualification], Qualification.citing_jobs_preload())

    AgentDocs.respond(conn,
      html:
        &render(&1, "show.html",
          qualification: qualification,
          page_title: entry_page_title(conn.assigns[:user], qualification)
        ),
      doc: fn ->
        SectionDocs.build_show(conn.assigns[:user], :qualifications, qualification)
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

    result = Repo.update(changeset)
    with {:ok, updated} <- result, do: store_document(updated, qualification_params)

    ControllerHelpers.save(conn, result,
      flash: gettext("Certificate or license updated successfully."),
      redirect_to: ~p"/settings/qualifications",
      render: "edit.html",
      assigns: [qualification: qualification]
    )
  end

  def delete(conn, _params) do
    qualification = conn.assigns[:qualification]

    conn =
      ControllerHelpers.delete(conn, qualification,
        flash: gettext("Certificate or license deleted successfully."),
        redirect_to: ~p"/settings/qualifications"
      )

    # The row is gone; its on-disk proof document must not stay orphaned.
    QualificationDocument.delete(qualification.id)
    conn
  end

  # Removes only the uploaded proof document; the credential entry stays.
  def delete_document(conn, _params) do
    qualification = conn.assigns[:qualification]

    qualification
    |> Ecto.Changeset.change(Qualification.document_reset_fields())
    |> Repo.update!()

    QualificationDocument.delete(qualification.id)

    conn
    |> put_flash(:info, gettext("The uploaded file was removed."))
    |> redirect(to: ~p"/settings/qualifications")
  end

  # Writes the proof-document files only after the row committed (the #776
  # rule: validate pre-commit, write post-commit, so a rolled-back save never
  # orphans files) and queues the AI scan, binding the verdict to exactly
  # these bytes. A row without document metadata means no (new) upload came.
  defp store_document(%Qualification{document: nil}, _params), do: :ok

  defp store_document(qualification, %{"document" => %Plug.Upload{} = upload}) do
    case QualificationDocument.store(upload, qualification.id) do
      {:ok, _meta} ->
        ImageScans.enqueue(
          "qualification_document",
          qualification.id,
          qualification.user_id,
          qualification.document_fingerprint
        )

        :ok

      {:error, reason} ->
        # validate/1 already passed pre-commit, so this is an environment
        # failure (disk). Keep the entry, drop the dangling reference.
        Logger.warning("qualification document store failed: #{inspect(reason)}")

        qualification
        |> Ecto.Changeset.change(Qualification.document_reset_fields())
        |> Repo.update!()

        :ok
    end
  end

  defp store_document(_qualification, _params), do: :ok

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
