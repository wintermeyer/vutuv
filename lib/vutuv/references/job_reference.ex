defmodule Vutuv.References.JobReference do
  @moduledoc """
  An Arbeitszeugnis a member holds: the German employment reference an
  employer must issue on request (§ 109 GewO, § 630 BGB, § 16 BBiG for a
  Berufsausbildung).

  Two things live on the row. The **document** is the scan or PDF the member
  received, stored the same consent-gated way a qualification's proof document
  is (`Vutuv.JobReferenceDocument`). The **body** is its plain text, either
  pasted directly or extracted from the file, and it is what the AI check
  actually reads — the model never sees the PDF.

  `public?` defaults to false and only leaves that state through an explicit
  tick. That is not politeness: a Zeugnis carries a former employer's graded
  judgement of a person, written in a code where "zufrieden" without "voll"
  means a bad mark. Publishing one by accident cannot be taken back, so the
  gate is a hard changeset error rather than a default a form could flip.
  """

  use VutuvWeb, :model

  alias Vutuv.Moderation.ImageScans
  alias Vutuv.References.Link
  alias Vutuv.Uploads

  # The Zeugnis kinds German law distinguishes; the analysis prompt asks for
  # this up front, because the claim basis differs per kind.
  @kinds ~w(qualified simple interim apprenticeship service)

  # Where `body` came from. Shown to the member: OCR text needs proofreading,
  # and a vision model's mistakes look like correct German rather than like
  # scanning errors.
  @body_sources ~w(typed pdf_text ocr_tesseract ocr_vision)

  # The body cap. ~13_500 tokens, which leaves room beside the ~35_200-token
  # analysis prompt inside the model's 65_536-token window. A 14-page Zeugnis
  # measured 9_543 characters, so this is roughly 80 pages of headroom.
  @max_body 50_000

  schema "job_references" do
    field(:title, :string)
    field(:employer, :string)
    field(:kind, :string, default: "qualified")
    field(:issued_on, :date)
    field(:country, :string)

    field(:body, :string)
    field(:body_source, :string)

    # The public-display choice and the evidence that it was made. Neither
    # `public_consented_at` nor the tick itself is mass-assignable: the
    # timestamp is stamped here, and the tick is virtual, so no API client can
    # publish a Zeugnis by sending a column.
    field(:public?, :boolean, default: false)
    field(:public_consented_at, :utc_datetime)
    field(:public_consent, :boolean, virtual: true)

    # When the member affirmed this Zeugnis is theirs to file, and the virtual
    # tick that stamps it. Same arrangement as the pair above and for the same
    # reason: a claim about a *third party's* data is worth nothing unless we
    # can say what was affirmed and when.
    field(:owner_confirmed_at, :utc_datetime)
    field(:owner_confirmation, :boolean, virtual: true)

    # The uploaded file. All set through `cast_document/2` or cleared through
    # `document_reset_fields/0`, never cast from params.
    field(:document, :string)
    field(:document_fingerprint, :string)
    field(:document_content_type, :string)
    field(:document_size, :integer)
    field(:document_moderation, :string)
    field(:document_page_count, :integer)

    belongs_to(:user, Vutuv.Accounts.User)
    has_many(:links, Link, on_replace: :delete)

    timestamps()
  end

  @cast_fields ~w(title employer kind issued_on country body body_source public?)a

  @doc """
  The visibility rule alone — published, and with any attached document cleared
  by moderation — applied to a query a caller is still building.

  Split out from `public_scope/0` because two other reads needed the rule but
  not the ordering or the bare source: the public show page filters by id, and
  `public_references_for/2` joins the links table first. Both had hand-copied
  the two `where`s, so the rule that decides whether somebody else's employment
  reference may be shown at all lived in three places — while the two web-layer
  call sites' comments named `public_scope()` as *the* guarantee, which was true
  of only one of them.
  """
  def visible(query) do
    from(r in query,
      where: r.public? == true,
      where: is_nil(r.document) or r.document_moderation == "approved"
    )
  end

  @doc """
  The query scope for what a visitor may see: `visible/1` plus the display
  order, newest issue date first.

  Shared by `Vutuv.References.public_job_references/1` and the profile card's
  preload, so a Zeugnis can never appear on one and not the other.
  """
  def public_scope do
    from(r in visible(__MODULE__), order_by: [desc_nulls_last: r.issued_on, desc: r.id])
  end

  @doc "The Zeugnis kinds a member may pick."
  def kinds, do: @kinds

  @doc "The known provenances of `body`."
  def body_sources, do: @body_sources

  @doc "The maximum accepted body length in characters."
  def max_body, do: @max_body

  @doc """
  The canonical form of a Zeugnis text: one line-ending style, LF.

  An HTML `<textarea>` submits its line breaks as CRLF whatever it was handed
  (HTML spec, "the API value" vs "the value"), so the body that comes back from
  the edit form is never byte-identical to the text extracted from the
  document — even when the member changed only the title or the visibility
  tick. Without this the text silently differs from the one every earlier AI
  review read, and `Vutuv.References.Check.current_for?/2` reports each of
  those reviews as describing an older version that never existed.

  Applied on the way in *and* inside `Vutuv.References.Checks.fingerprint/1`,
  so a body already stored with carriage returns is read as the same text
  rather than needing a re-save to become one.
  """
  def normalize_body(nil), do: nil

  def normalize_body(body) when is_binary(body),
    do: body |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")

  @doc """
  Creates a changeset from `model` and `params`.

  `user_id` is never cast — the context sets it from the authenticated member,
  so no request can file a Zeugnis onto somebody else's profile.
  """
  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @cast_fields)
    |> update_change(:body, &normalize_body/1)
    |> lock_body()
    |> put_default_country()
    |> validate_required([:title, :country])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:body_source, @body_sources)
    |> validate_format(:country, ~r/\A[A-Z]{2}\z/)
    # Match the varchar(255) columns, or an oversized value raises Postgres
    # 22001 (a 500 on a plain form submit) instead of a field error.
    |> validate_length(:title, max: 255)
    |> validate_length(:employer, max: 255)
    |> validate_length(:body, max: @max_body)
    |> cast_ownership(params)
    |> cast_visibility(params)
  end

  # Asked once, when the entry is created, and never again.
  #
  # A Zeugnis is a named person's employment history plus a graded judgement of
  # them, and here a language model reads it too. Filing somebody else's is not
  # a house rule but the processing of another human's personal data with
  # nothing behind it, so the question is put at the moment of the act and the
  # save does not happen without an answer.
  #
  # Not on every edit: the tick would then sit unanswered under a title change
  # that needs no permission, and a gate a member steps over weekly is a gate
  # they stop reading — the same argument that moved the publish tick to the
  # one step where it can apply.
  defp cast_ownership(changeset, params) do
    if new_entry?(changeset) do
      require_ownership(changeset, params)
    else
      changeset
    end
  end

  # Ecto's own insert-or-update signal, rather than a nil id: it is the same
  # question `Repo.insert/2` asks, and a struct can carry an id without being
  # in the database yet.
  defp new_entry?(%Ecto.Changeset{data: %__MODULE__{__meta__: %{state: :built}}}), do: true
  defp new_entry?(_existing), do: false

  defp require_ownership(changeset, params) do
    confirmed? = (params["owner_confirmation"] || params[:owner_confirmation]) in [true, "true"]

    if confirmed? do
      put_change(changeset, :owner_confirmed_at, DateTime.utc_now(:second))
    else
      add_error(
        changeset,
        :owner_confirmation,
        "Please confirm that this reference is yours to upload. Somebody else's reference needs their explicit agreement first."
      )
    end
  end

  @doc """
  Refuses an entry that carries neither a document nor a text.

  A Zeugnis with nothing in it is not a Zeugnis: nothing to show on a profile,
  nothing to attach to a CV, nothing for the review to read. It used to be
  storable, which left a member with a row that looked like an entry and did
  none of the things an entry does.

  Called by `Vutuv.References` **after** `cast_document/2` rather than from
  inside `changeset/2`, because the file arrives on its own path and the
  changeset has not seen it yet at that point. `get_field/2` answers with the
  newly uploaded file or the one already stored, so replacing a document does
  not momentarily look like removing it.
  """
  def validate_content(changeset) do
    body = changeset |> get_field(:body) |> to_string() |> String.trim()
    document = get_field(changeset, :document)

    if body != "" or is_binary(document) do
      changeset
    else
      add_error(
        changeset,
        :document,
        "is missing. Upload the document, or paste the text of the reference."
      )
    end
  end

  @doc """
  Whether this entry's text is settled and may no longer be edited.

  True as soon as it holds one. The reason is not tidiness: the AI review
  grades this exact wording against § 109 GewO, and a published Zeugnis is
  shown to strangers as a former employer's own words — both claims collapse
  the moment the person being judged can rewrite the judgement. So the text is
  what the document said, and correcting a misread scan means replacing the
  entry rather than improving its wording.

  A body that is still empty stays writable: an entry whose extraction failed
  would otherwise be a dead end, and there is nothing there to protect yet.
  """
  def text_locked?(%__MODULE__{body: body}), do: is_binary(body) and String.trim(body) != ""

  # Enforced here rather than with a `readonly` attribute on the form, so a
  # crafted POST and an API client hit the same wall the form does. Silently
  # dropped rather than refused: the member is not doing anything wrong when
  # they save a form that carried the field along, and an error on a field they
  # were never invited to change would be a puzzle, not a message. The
  # provenance goes with it — a locked text must not be able to relabel itself
  # as typed by hand.
  defp lock_body(changeset) do
    if text_locked?(changeset.data) do
      changeset |> delete_change(:body) |> delete_change(:body_source)
    else
      changeset
    end
  end

  # An entry always names a country, because the analysis is bound to one
  # country's law. Uppercased rather than rejected: a form or an API client
  # sending "de" means Germany, and failing that submit would teach nobody
  # anything.
  defp put_default_country(changeset) do
    case get_field(changeset, :country) do
      nil -> put_change(changeset, :country, Vutuv.Geo.default_country())
      code -> put_change(changeset, :country, String.upcase(code))
    end
  end

  # The public gate. Going from private to public needs the tick in the same
  # submit; staying public across an unrelated edit does not, or every change
  # to an already-public entry would demand the member re-consent.
  #
  # Going back to private clears the stamp: it consented to *being public*, and
  # a stale timestamp on a private row would misread as "they agreed to this"
  # the next time anyone looked.
  defp cast_visibility(changeset, params) do
    case {get_field(changeset, :public?), changeset.data.public?} do
      {true, true} -> changeset
      {true, _was} -> require_consent(changeset, params)
      {_now, _was} -> put_change(changeset, :public_consented_at, nil)
    end
  end

  defp require_consent(changeset, params) do
    consented? = (params["public_consent"] || params[:public_consent]) in [true, "true"]

    if consented? do
      put_change(changeset, :public_consented_at, DateTime.utc_now(:second))
    else
      add_error(
        changeset,
        :public_consent,
        "Please confirm that this reference may be shown publicly. Without your consent it stays private."
      )
    end
  end

  @doc """
  Attaches an uploaded document to the changeset.

  Only a real `%Plug.Upload{}` counts, so the JSON API cannot smuggle document
  columns in. Unlike a qualification's proof this needs no separate consent:
  the file inherits the entry's own `public?` state, and that is where the
  consent gate already sits. The bytes are written only after the row
  committed (`Vutuv.JobReferenceDocument.store/2`).
  """
  def cast_document(changeset, params) do
    case params["document"] || params[:document] do
      %Plug.Upload{} = upload -> cast_document_upload(changeset, upload)
      _none -> changeset
    end
  end

  defp cast_document_upload(changeset, upload) do
    case Vutuv.JobReferenceDocument.validate(upload) do
      :ok -> put_document_meta(changeset, upload)
      {:error, reason} -> add_error(changeset, :document, document_error(reason))
    end
  end

  defp put_document_meta(changeset, upload) do
    changeset
    |> put_change(:document, upload.filename)
    |> put_change(:document_fingerprint, Uploads.content_hash(upload.path))
    |> put_change(:document_content_type, MIME.from_path(upload.filename))
    |> put_change(:document_size, File.stat!(upload.path).size)
    |> put_change(:document_moderation, ImageScans.initial_state())
    |> validate_length(:document, max: 255)
  end

  defp document_error(:too_large),
    do: "is larger than 10 MB. Please upload a smaller file."

  defp document_error(:pdf_unsupported),
    do: "PDF uploads are not available on this installation. Please paste the text instead."

  defp document_error(:invalid_file),
    do: "could not be read. Please upload a PDF, JPG, PNG or WebP file."

  @doc """
  The nil-out keyword for every document column — one list shared by the
  owner's "remove file" action, the store-failure fallback and the moderation
  rejection, so no path can forget a column.
  """
  def document_reset_fields,
    do: [
      document: nil,
      document_fingerprint: nil,
      document_content_type: nil,
      document_size: nil,
      document_moderation: nil,
      document_page_count: nil
    ]

  @doc "Whether a document is stored on this entry."
  def document?(%__MODULE__{document: document}), do: is_binary(document)

  @doc """
  Whether the stored document has been released by the AI image scan; until
  then only the owner sees it, and the proxy enforces the same rule.
  """
  def document_released?(%__MODULE__{} = reference) do
    document?(reference) and ImageScans.released?(reference.document_moderation)
  end

  @doc """
  Whether this entry is visible to anyone but its owner: the member published
  it *and* any attached document cleared moderation. A pasted-text entry with
  no document is public on the member's word alone.
  """
  def publicly_visible?(%__MODULE__{public?: false}), do: false

  def publicly_visible?(%__MODULE__{} = reference) do
    not document?(reference) or document_released?(reference)
  end
end
