defmodule VutuvWeb.JobReferenceController do
  @moduledoc """
  Arbeitszeugnisse: the member's own list under `/settings/job_references`,
  and the public list on a profile.

  Two things here differ from the qualification controller it is otherwise
  modelled on. An upload is **read** as well as stored — the extracted text is
  what the AI analysis reads, and it is put in front of the member for
  proof-reading rather than used silently. And nothing is public by default:
  `public?` starts false and only moves through an explicit tick, so the
  public list is usually empty even for a member with several entries.
  """

  use VutuvWeb, :controller

  require Logger

  alias Vutuv.AccountEvents
  alias Vutuv.JobReferenceDocument
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.References
  alias Vutuv.References.Check
  alias Vutuv.References.Checks
  alias Vutuv.References.JobReference
  alias Vutuv.References.Link
  alias Vutuv.References.TextExtraction
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.SectionDocs
  alias VutuvWeb.ControllerHelpers

  plug(VutuvWeb.Plug.AuthUser when action not in [:index, :show])
  plug(:scrub_params, "job_reference" when action in [:create, :update])

  # Keyed by UUID rather than a slug: a Zeugnis title is neither unique nor
  # URL-safe, and an owner-scoped resolver casts the id safely.
  plug(
    :resolve_reference
    when action in [:show, :show_own, :edit, :update, :delete, :create_check, :show_check]
  )

  ## Public

  # Index and show are also served as Markdown / text / JSON / XML through
  # VutuvWeb.AgentDocs.SectionDocs (keep the templates and the doc builder in
  # sync — agent_docs_drift_test.exs). Both render the anonymous public view,
  # so the AI review never appears in any of them.
  def index(conn, _params) do
    user = conn.assigns[:user]
    references = References.public_job_references(user)

    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "index.html",
          user: user,
          references: references,
          page_title:
            VutuvWeb.UserHelpers.member_page_title(user, gettext("Employment references"))
        )
      end,
      doc: fn -> SectionDocs.build_index(user, :job_references, references) end
    )
  end

  def show(conn, _params) do
    reference = conn.assigns[:job_reference]
    user = conn.assigns[:user]

    # The owner reaches their own private entry through /settings; this page
    # is the anonymous public view and shows only what was published.
    if JobReference.publicly_visible?(reference) do
      AgentDocs.respond(conn,
        html: fn conn ->
          render(conn, "show.html",
            user: user,
            reference: reference,
            page_title: VutuvWeb.UserHelpers.member_page_title(user, reference.title)
          )
        end,
        doc: fn -> SectionDocs.build_show(user, :job_references, reference) end
      )
    else
      conn |> ControllerHelpers.render_error(404) |> halt()
    end
  end

  ## The owner's editor

  def manage(conn, _params) do
    user = conn.assigns[:current_user]

    render(conn, "manage.html",
      user: user,
      references: References.list_job_references(user),
      checks: latest_checks(user),
      page_title: gettext("Employment references")
    )
  end

  # The owner's own page for one Zeugnis. It exists because everything else
  # here shows the document at thumbnail size or not at all: the editor listed
  # it, the edit form let them replace it, and the only way to *read* the thing
  # they uploaded was the public page — which a private Zeugnis, i.e. nearly
  # every Zeugnis, does not have.
  def show_own(conn, _params) do
    reference = conn.assigns[:job_reference]

    render(conn, "view.html",
      user: conn.assigns[:current_user],
      reference: reference,
      check: Checks.latest_for(reference),
      page_title: reference.title
    )
  end

  def new(conn, _params) do
    render(conn, "new.html",
      changeset: References.change_job_reference(%JobReference{}),
      cv_entries: cv_entries(conn.assigns[:current_user]),
      selected: [],
      page_title: gettext("Add an employment reference")
    )
  end

  def create(conn, %{"job_reference" => params}) do
    user = conn.assigns[:current_user]

    case References.create_job_reference(user, params) do
      {:ok, reference} ->
        reference = store_document_and_extract(reference, params)
        put_links(reference, params)
        AccountEvents.record(user, "job_reference_added", conn: conn)

        conn
        |> put_flash(:info, gettext("Employment reference saved."))
        |> redirect(to: ~p"/settings/job_references")

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render("new.html",
          changeset: changeset,
          cv_entries: cv_entries(user),
          selected: submitted_links(params),
          page_title: gettext("Add an employment reference")
        )
    end
  end

  def edit(conn, _params) do
    reference = conn.assigns[:job_reference]

    render(conn, "edit.html",
      reference: reference,
      changeset: References.change_job_reference(reference),
      cv_entries: cv_entries(conn.assigns[:current_user]),
      selected: linked_subjects(reference),
      page_title: gettext("Edit employment reference")
    )
  end

  def update(conn, %{"job_reference" => params}) do
    reference = conn.assigns[:job_reference]

    case References.update_job_reference(reference, params) do
      {:ok, updated} ->
        updated = store_document_and_extract(updated, params)
        put_links(updated, params)

        # Only the NAMES of the fields that were submitted — the same rule the
        # profile editor follows. What a Zeugnis says belongs to the Zeugnis,
        # not to a log that outlives it.
        AccountEvents.record(updated.user_id, "job_reference_updated",
          conn: conn,
          details: %{fields: changed_field_names(params)}
        )

        conn
        |> put_flash(:info, gettext("Employment reference updated."))
        |> redirect(to: ~p"/settings/job_references")

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render("edit.html",
          reference: reference,
          changeset: changeset,
          cv_entries: cv_entries(conn.assigns[:current_user]),
          selected: submitted_links(params),
          page_title: gettext("Edit employment reference")
        )
    end
  end

  # The only way a stored file leaves by the member's own hand. There is
  # deliberately no "remove just the file": the review grades the text, but the
  # text is only worth something because a document was read to produce it, so
  # an entry that kept one without the other would be a claim with nothing
  # behind it. The confirmation therefore names the document and the review.
  def delete(conn, _params) do
    reference = conn.assigns[:job_reference]

    conn =
      ControllerHelpers.delete(conn, reference,
        flash: gettext("Employment reference deleted."),
        redirect_to: ~p"/settings/job_references"
      )

    AccountEvents.record(reference.user_id, "job_reference_removed", conn: conn)

    # Links and checks cascade in the database; the files do not.
    JobReferenceDocument.delete(reference.id)
    conn
  end

  # Queues the analysis. Every refusal names its own reason: a member who
  # presses a button and is told nothing assumes the feature is broken.
  def create_check(conn, _params) do
    reference = conn.assigns[:job_reference]

    conn
    |> put_flash_for(Checks.enqueue(reference))
    |> redirect(to: ~p"/settings/job_references")
  end

  # The finished analysis, full width and on its own. A dead page on purpose:
  # a done result never changes again, so it needs no socket — the panel in the
  # list is the live part, and it links here.
  def show_check(conn, _params) do
    reference = conn.assigns[:job_reference]

    case Checks.latest_for(reference) do
      %{status: "done"} = check ->
        render(conn, "check.html",
          user: conn.assigns[:current_user],
          reference: reference,
          check: check,
          current?: Check.current_for?(check, reference),
          page_title: gettext("Review result")
        )

      _none_yet ->
        conn
        |> put_flash(:info, gettext("There is no review result for this reference yet."))
        |> redirect(to: ~p"/settings/job_references")
    end
  end

  defp put_flash_for(conn, {:ok, _check}),
    do: put_flash(conn, :info, gettext("The review has been queued."))

  defp put_flash_for(conn, {:error, :already_queued}),
    do: put_flash(conn, :info, gettext("A review for this reference is already running."))

  defp put_flash_for(conn, {:error, :no_body}),
    do:
      put_flash(
        conn,
        :error,
        gettext("There is no text to review yet. Upload the document or paste the text.")
      )

  defp put_flash_for(conn, {:error, :unsupported_country}),
    do:
      put_flash(
        conn,
        :error,
        gettext("The review covers German employment references only.")
      )

  # The wait is computed from the same window the limit is counted over, so
  # the sentence cannot promise a time the code does not honour.
  defp put_flash_for(conn, {:error, :rate_limited}) do
    user_id = conn.assigns[:current_user] && conn.assigns[:current_user].id

    put_flash(conn, :error, VutuvWeb.JobReferenceHTML.rate_limit_message(user_id))
  end

  defp put_flash_for(conn, {:error, :disabled}),
    do: put_flash(conn, :error, gettext("The review is not available on this installation."))

  ## Helpers

  # Writes the files only after the row committed (validate pre-commit, write
  # post-commit, so a rolled-back save never orphans files), queues the AI
  # scan bound to exactly these bytes, and reads the text out of the document.
  defp store_document_and_extract(%JobReference{document: nil} = reference, _params),
    do: reference

  defp store_document_and_extract(reference, %{"document" => %Plug.Upload{} = upload}) do
    case JobReferenceDocument.store(upload, reference.id) do
      {:ok, meta} ->
        ImageScans.enqueue(
          "job_reference_document",
          reference.id,
          reference.user_id,
          reference.document_fingerprint
        )

        reference
        |> Ecto.Changeset.change(document_page_count: meta.page_count)
        |> Repo.update!()
        |> maybe_extract_text()

      {:error, reason} ->
        # validate/1 already passed pre-commit, so this is an environment
        # failure (disk). Keep the entry, drop the dangling reference.
        Logger.warning("job reference document store failed: #{inspect(reason)}")

        reference
        |> Ecto.Changeset.change(JobReference.document_reset_fields())
        |> Repo.update!()
    end
  end

  defp store_document_and_extract(reference, _params), do: reference

  # Only fills the body when the member left it empty: their own text always
  # wins over anything a machine read, and an edit that re-uploads the file
  # must not silently discard corrections they made.
  defp maybe_extract_text(%JobReference{body: body} = reference)
       when is_binary(body) and body != "" do
    reference
  end

  defp maybe_extract_text(reference) do
    case JobReferenceDocument.original_path(reference.id) do
      nil ->
        reference

      path ->
        case TextExtraction.extract(path) do
          {:ok, text, source} ->
            reference
            |> Ecto.Changeset.change(body: text, body_source: source)
            |> Repo.update!()

          {:error, reason} ->
            Logger.info("job reference text extraction failed: #{inspect(reason)}")
            reference
        end
    end
  end

  defp put_links(reference, params), do: References.put_links(reference, submitted_links(params))

  # The submitted field names, whitelisted — never their values (issue #1087).
  @logged_fields ~w(title employer kind issued_on country body public? document)

  defp changed_field_names(params) do
    params
    |> Map.keys()
    |> Enum.filter(&(&1 in @logged_fields))
    |> Enum.sort()
  end

  # The form posts `links[]` entries shaped "work_experience:<uuid>". Anything
  # else is dropped here; the context drops anything the member does not own.
  defp submitted_links(params) do
    params
    |> Map.get("links", [])
    |> List.wrap()
    |> Enum.flat_map(fn value ->
      case String.split(to_string(value), ":", parts: 2) do
        [kind, id] when kind in ~w(work_experience education qualification) ->
          [{String.to_existing_atom(kind), id}]

        _malformed ->
          []
      end
    end)
  end

  defp linked_subjects(reference) do
    reference.links
    |> Enum.map(&Link.subject/1)
    |> Enum.reject(&is_nil/1)
  end

  # What the form offers to link against, grouped by kind.
  defp cv_entries(user) do
    user = Repo.preload(user, [:work_experiences, :educations, :qualifications])

    %{
      work_experience: user.work_experiences,
      education: user.educations,
      qualification: user.qualifications
    }
  end

  defp latest_checks(user) do
    user
    |> References.list_job_references()
    |> Map.new(fn reference -> {reference.id, Checks.latest_for(reference)} end)
  end

  defp resolve_reference(conn, _opts) do
    owner = conn.assigns[:user] || conn.assigns[:current_user]

    case ControllerHelpers.get_owned(owner, :job_references, conn.params["id"]) do
      %JobReference{} = reference ->
        assign(conn, :job_reference, Repo.preload(reference, :links))

      nil ->
        conn |> ControllerHelpers.render_error(404) |> halt()
    end
  end
end
