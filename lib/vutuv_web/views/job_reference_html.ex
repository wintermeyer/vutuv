defmodule VutuvWeb.JobReferenceHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  alias Vutuv.Countries
  alias Vutuv.JobReferenceDocument
  alias Vutuv.References
  alias Vutuv.References.Analyst
  alias Vutuv.References.Check
  alias Vutuv.References.Checks
  alias Vutuv.References.JobReference
  alias Vutuv.References.Link
  alias Vutuv.References.Skill

  embed_templates("../templates/job_reference/*")

  @doc "The name of a Zeugnis kind, for the picker and the row badge."
  def kind_name("qualified"), do: gettext("Qualifiziertes Zeugnis")
  def kind_name("simple"), do: gettext("Einfaches Zeugnis")
  def kind_name("interim"), do: gettext("Zwischenzeugnis")
  def kind_name("apprenticeship"), do: gettext("Ausbildungszeugnis")
  def kind_name("service"), do: gettext("Dienstzeugnis")
  def kind_name(_unknown), do: gettext("Reference")

  @doc "The `{label, value}` options for the kind select."
  def kind_options, do: for(kind <- JobReference.kinds(), do: {kind_name(kind), kind})

  @doc """
  The country select's options, keyed by **ISO 3166-1 alpha-2 code**.

  Deliberately not `AddressHTML.country_options/1`, which yields country
  *names*: that field is free text a member may have filled in years ago in
  any spelling, while this one decides whether the AI review is offered at
  all, so it has to be a code the configuration can match exactly.

  The countries the review covers are listed first, because on a German
  installation they are what nearly every member wants.
  """
  def country_options(current \\ nil) do
    all = Countries.select_options(Gettext.get_locale(VutuvWeb.Gettext))
    covered = References.check_countries()

    {preferred, rest} = Enum.split_with(all, fn {_label, code} -> code in covered end)

    options = preferred ++ rest

    if is_binary(current) and current != "" and
         not Enum.any?(options, fn {_label, code} -> code == current end) do
      options ++ [{current, current}]
    else
      options
    end
  end

  @doc """
  How the text was obtained, said plainly.

  Machine-read text is labelled as such wherever it is shown: OCR does not
  merely make mistakes, a vision model makes *plausible* ones, so the member
  needs to know they are proof-reading rather than reading.
  """
  def source_note("typed"), do: nil
  def source_note("pdf_text"), do: gettext("Read from the PDF.")

  def source_note("ocr_tesseract"),
    do: gettext("Read from a scan by text recognition. Please check it.")

  def source_note("ocr_vision"),
    do: gettext("Read from a scan by an AI model. Please check it carefully.")

  def source_note(_unknown), do: nil

  @doc "Whether the text was produced by a machine rather than typed."
  def machine_read?(source), do: source in ~w(pdf_text ocr_tesseract ocr_vision)

  @doc """
  Whether a virtual consent tick was ticked on the submit being re-rendered.

  The two ticks on this form are not cast onto the schema (they must never be
  mass-assignable), so nothing carries them back into a re-rendered form and a
  member who trips any *other* validation finds them cleared. That is merely
  annoying for the publish tick and corrosive for the ownership one, which
  fails the save on its own: re-ticking a promise on every attempt is how a
  promise stops being read. The raw params the changeset kept are the one place
  the answer survives.
  """
  def consent_ticked?(%Ecto.Changeset{params: params}, field) when is_map(params),
    do: params[to_string(field)] in [true, "true"]

  def consent_ticked?(_changeset, _field), do: false

  @doc "Whether the ownership tick was ticked on the submit being re-rendered."
  def owner_confirmation_ticked?(changeset),
    do: consent_ticked?(changeset, :owner_confirmation)

  @doc """
  Whether the form is editing an entry whose text is already settled.

  Takes the template's whole assigns, because the new form has no `:reference`
  at all — and a form with nothing to protect must stay writable, or pasting a
  text would be impossible.
  """
  def text_locked?(assigns) do
    case assigns[:reference] do
      %JobReference{} = reference -> JobReference.text_locked?(reference)
      _new_entry -> false
    end
  end

  @doc """
  The upload cap as a member reads it, from the one place that enforces it.

  Written out rather than typed into the copy, so the sentence on the form and
  the rule in `Vutuv.JobReferenceDocument.validate/1` cannot drift apart.
  """
  def max_upload_label do
    mb = div(JobReferenceDocument.max_size(), 1_000_000)
    "#{mb} MB"
  end

  @doc "Whether the stored document is a PDF, which decides how it is shown."
  def pdf?(%JobReference{document_content_type: type}), do: type == "application/pdf"

  @doc "The thumbnail URL for an entry's document, or nil."
  def thumb_url(%JobReference{} = reference, user) do
    version_url(reference, user, :thumb)
  end

  @doc "The larger preview URL, or nil."
  def page_url(%JobReference{} = reference, user), do: version_url(reference, user, :page)

  defp version_url(%JobReference{document_fingerprint: nil}, _user, _version), do: nil

  defp version_url(reference, user, version) do
    if JobReferenceDocument.version_path(reference.id, version) do
      file = "#{version}-#{reference.document_fingerprint}.avif"
      ~p"/#{user.username}/job_references/#{reference.id}/document/#{file}"
    end
  end

  @doc """
  What the stored file is, in one line: kind · size · pages.

  Shown beside the file name on the edit form, because "remove this file" is
  not a question anybody can answer about a document they cannot see.
  """
  def document_label(%JobReference{} = reference) do
    [
      document_type_word(reference.document_content_type),
      file_size_label(reference.document_size),
      page_label(reference.document_page_count)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp document_type_word("application/pdf"), do: "PDF"
  defp document_type_word(nil), do: nil
  defp document_type_word(_image), do: gettext("Image")

  # KB below 1 MB, else MB with one decimal — decimal comma under German, the
  # `delimited_count/1` locale convention.
  defp file_size_label(nil), do: nil

  defp file_size_label(bytes) when bytes < 1_000_000, do: "#{max(div(bytes, 1000), 1)} KB"

  defp file_size_label(bytes) do
    tenths = div(bytes, 100_000)
    separator = if Gettext.get_locale(VutuvWeb.Gettext) == "de", do: ",", else: "."
    "#{div(tenths, 10)}#{separator}#{rem(tenths, 10)} MB"
  end

  defp page_label(nil), do: nil

  # `ngettext/3` auto-binds `%{count}` to the raw integer and a `count:` binding
  # does not override it, so the formatted figure rides its own placeholder.
  defp page_label(count),
    do:
      ngettext("%{formatted} page", "%{formatted} pages", count, formatted: compact_count(count))

  @doc "The download URL of the document itself, or nil."
  def document_url(%JobReference{document_fingerprint: nil}, _user), do: nil

  def document_url(reference, user) do
    ext = JobReferenceDocument.public_ext(reference.document_content_type)
    file = "#{reference.document_fingerprint}#{ext}"
    ~p"/#{user.username}/job_references/#{reference.id}/document/#{file}"
  end

  @doc """
  The CV entries a **published** reference documents, as short labels.

  What a Zeugnis is *about* is most of what it says, so the profile card names
  it rather than leaving a reader to match employers by eye. Resolved against
  the member's already-preloaded CV lists, so it costs no query — and returns
  `[]` when the linked entry is outside the profile's preview limit, where a
  label would name something the page does not show.

  Only ever called for entries the profile loaded, which is
  `JobReference.public_scope()` — a private Zeugnis reaches no reader here, so
  neither does the fact that it documents a particular job.
  """
  def linked_entry_labels(%JobReference{links: links}, user) when is_list(links) do
    entries = %{
      work_experience: Map.get(user, :work_experiences) || [],
      education: Map.get(user, :educations) || [],
      qualification: Map.get(user, :qualifications) || []
    }

    links
    |> Enum.map(&subject_label(&1, entries))
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  def linked_entry_labels(_reference, _user), do: []

  @doc """
  The published references documenting one CV entry, keyed by the entry's id.

  Built once from the references the profile already loaded, so a timeline of
  twenty roles costs no queries at all — the alternative, asking per entry,
  is the shape that quietly turns one card into twenty round trips.
  """
  def references_by_subject(references) when is_list(references) do
    for reference <- references,
        link <- reference.links || [],
        {_kind, id} = pair when not is_nil(pair) <- [Link.subject(link)],
        reduce: %{} do
      acc -> Map.update(acc, id, [reference], &[reference | &1])
    end
  end

  def references_by_subject(_references), do: %{}

  @doc "A short human label for the linked CV entry behind a link row."
  def subject_label(%Link{} = link, entries) do
    case Link.subject(link) do
      {kind, id} -> entries |> Map.get(kind, []) |> Enum.find(&(&1.id == id)) |> entry_label()
      nil -> nil
    end
  end

  @doc "A one-line name for a CV entry of any of the three kinds."
  def entry_label(%Vutuv.Profiles.WorkExperience{} = job) do
    [job.title, job.organization] |> Enum.reject(&blank?/1) |> Enum.join(" · ")
  end

  def entry_label(%Vutuv.Profiles.Education{} = education) do
    [education.degree, education.school] |> Enum.reject(&blank?/1) |> Enum.join(" · ")
  end

  def entry_label(%Vutuv.Profiles.Qualification{} = qualification) do
    [qualification.name, qualification.issuer] |> Enum.reject(&blank?/1) |> Enum.join(" · ")
  end

  def entry_label(_none), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  @doc "The heading for one group of CV entries in the link picker."
  def entries_heading(:work_experience), do: gettext("Experience")
  def entries_heading(:education), do: gettext("Education")
  def entries_heading(:qualification), do: gettext("Certificates & licenses")

  @doc "The form value for one CV entry, as the controller parses it back."
  def link_value(kind, entry), do: "#{kind}:#{entry.id}"

  @doc "Whether the AI check applies to this entry's country."
  def check_supported?(reference), do: References.check_supported?(reference)

  @doc "Whether this installation offers the check at all."
  def checks_enabled?, do: Checks.enabled?()

  @doc "The project behind the analysis prompt, credited under every result."
  def skill_project_url, do: Skill.project_url()

  @doc "The exact model tag this installation runs, for the transparency box."
  def reference_check_model, do: Analyst.model()

  @doc """
  The headline of the transparency box: where the Zeugnis stays.

  It used to read "Your reference stays here.", which answers the question a
  member is asking with the word they asked it about — "here" is a website, and
  what they want to know is which country the machine stands in. So the country
  is named, and it is named from configuration (`Analyst.country/0`, an ISO
  code so `Vutuv.Countries` can put it in the reader's own language): a
  template spelling out one operator's country would be a lie on the next
  operator's server, and this is exactly the box where a lie costs the most.
  Where no country is configured the promise falls back to what is still true
  everywhere, that the servers are ours.
  """
  def check_location_heading do
    case country_name() do
      nil -> gettext("Your reference stays on our own servers.")
      country -> gettext("Your reference stays on our servers in %{country}.", country: country)
    end
  end

  @doc """
  The sentence under that heading: whose machines it runs on.

  The country belongs to the heading, so this carries the other concrete fact —
  the hardware, also from configuration, and also skippable, because an
  operator who does not want to name their box still gets a sentence that is
  true.
  """
  def check_location_line do
    case Analyst.hardware() do
      nil ->
        gettext("It is analysed right here, on our own machines.")

      hardware ->
        gettext("It is analysed right here, on our own hardware: %{hardware}.",
          hardware: hardware
        )
    end
  end

  defp country_name do
    case Analyst.country() do
      nil -> nil
      code -> Countries.name(code, Gettext.get_locale(VutuvWeb.Gettext))
    end
  end

  @doc """
  What to tell a member who has used their allowance.

  The old sentence said "please try again tomorrow", which is not what the code
  does: the allowance is a **rolling** window, so somebody who used their last
  slot at 23:00 is free again at 23:00 the next day, not at midnight. This says
  how long is actually left, from the same window the limit is counted over —
  a wait a member can plan around instead of a day they might waste.

  Relative rather than a clock time on purpose: a flash carries no timezone,
  and "in about 3 hours" is right for every reader.

  Both wordings name a number and a time, including the **fallback** for a
  member with nothing in the window to count the next slot from. That one used
  to read "You have used your reviews for now. Please try again later.", which
  says neither how many there were nor when they come back: "later" is not
  something anyone can plan around, and a member who reads it has no way to
  tell whether to wait ten minutes or a day. It quotes the whole window, which
  is the longest the wait can possibly be.
  """
  def rate_limit_message(user_id) do
    case Checks.next_slot_at(user_id) do
      nil ->
        gettext("You have reached your limit of %{limit} reviews. Please try again in %{window}.",
          limit: compact_count(Checks.daily_limit()),
          window: window_phrase()
        )

      at ->
        gettext(
          "You have used your %{limit} reviews for the last %{window}. The next one is possible again in about %{wait}.",
          limit: compact_count(Checks.daily_limit()),
          window: window_phrase(),
          wait: wait_phrase(at)
        )
    end
  end

  # Read from the same constant the limit is counted over, so the rule and the
  # sentence describing it cannot drift apart.
  defp window_phrase, do: hours_phrase(div(Checks.window_seconds(), 3_600))

  # Rounded up, and never "0": a member told to wait zero minutes would try
  # again and be refused.
  defp wait_phrase(at) do
    seconds = max(DateTime.diff(at, DateTime.utc_now()), 60)

    if seconds < 3_600 do
      minutes_phrase(ceil(seconds / 60))
    else
      hours_phrase(ceil(seconds / 3_600))
    end
  end

  defp minutes_phrase(count),
    do: ngettext("%{formatted} minute", "%{formatted} minutes", count, formatted: count)

  defp hours_phrase(count),
    do: ngettext("%{formatted} hour", "%{formatted} hours", count, formatted: count)

  @doc "The queue position of a waiting check, or nil."
  def queue_position(%Check{} = check), do: Checks.queue_position(check)
  def queue_position(_none), do: nil

  @doc """
  Whether a finished check still describes the entry's current text.

  A stale result is shown, not hidden: the earlier reading is still worth
  having, it simply no longer matches what is on screen.
  """
  def current_result?(%Check{} = check, reference), do: Check.current_for?(check, reference)
  def current_result?(_none, _reference), do: false

  @doc """
  The one-line fact strip under a Zeugnis title: kind · employer · issue date.

  One definition for all three pages that show it (the owner's editor, the
  public list, the public single page), so a member cannot see their entry
  described one way here and another way on their profile.
  """
  attr(:reference, :any, required: true)
  attr(:class, :string, default: nil)

  def reference_meta(assigns) do
    ~H"""
    <p class={["text-sm text-slate-600 dark:text-slate-400", @class]}>
      <span>{kind_name(@reference.kind)}</span>
      <span :if={@reference.employer}>· {@reference.employer}</span>
      <span :if={@reference.issued_on}>· {issued_on(@reference.issued_on)}</span>
    </p>
    """
  end

  @doc """
  An issue date as the reader's locale writes one.

  The bare `Date` prints ISO-8601, which on a German page reads as a machine
  stamp rather than a date. The agent-format siblings keep ISO — that is the
  form a machine wants, and this is the form a person wants.
  """
  def issued_on(%Date{} = date) do
    case Gettext.get_locale(VutuvWeb.Gettext) do
      "de" -> Calendar.strftime(date, "%d.%m.%Y")
      _other -> Calendar.strftime(date, "%Y-%m-%d")
    end
  end

  def issued_on(_none), do: nil

  @doc """
  The grade the review arrived at, as a tinted label — the payload of the whole
  feature, and the one line a member scanning several Zeugnisse reads.

  Rendered twice, from one definition: compact in the list row
  (`variant={:inline}`) and as the leading verdict on the result page
  (`variant={:panel}`), so the two can never state the grade differently.

  The tint is emerald / slate / rose (`Check.grade_band/1`), deliberately with
  **no amber step**: amber is this app's moderation colour (`<.frozen_banner>`,
  the photo-check panel), and a middling grade is not a moderation notice. A
  grade the parser did not recognise renders nothing at all rather than an
  empty box.
  """
  attr(:check, :any, required: true)
  attr(:variant, :atom, default: :inline)
  attr(:class, :string, default: nil)

  def grade_label(assigns) do
    assigns =
      assigns
      |> assign(span: Check.grade_span(assigns.check))
      |> assign(band: Check.grade_band(assigns.check))

    ~H"""
    <div
      :if={@span}
      class={[grade_tint(@band), grade_shape(@variant), @class]}
      data-grade-band={@band || "unknown"}
    >
      <span class={[
        "font-semibold uppercase tracking-wide",
        @variant == :panel && "block text-xs opacity-80",
        @variant == :inline && "text-xs"
      ]}>
        {gettext("Overall grade")}
      </span>
      <span class={[@variant == :panel && "mt-0.5 block text-lg font-semibold"]}>{@span}</span>
    </div>
    """
  end

  defp grade_shape(:panel), do: "rounded-lg px-4 py-3"

  defp grade_shape(:inline),
    do: "inline-flex flex-wrap items-baseline gap-x-2 gap-y-0.5 rounded-lg px-3 py-1.5 text-sm"

  defp grade_tint(:good),
    do:
      "bg-emerald-50 text-emerald-900 ring-1 ring-emerald-200 dark:bg-emerald-900/30 dark:text-emerald-100 dark:ring-emerald-800"

  defp grade_tint(:poor),
    do:
      "bg-rose-50 text-rose-900 ring-1 ring-rose-200 dark:bg-rose-900/30 dark:text-rose-100 dark:ring-rose-800"

  # `:average` and an unrecognised band share the neutral treatment: a grade 3
  # is the middle of the scale, and a line we could not read must not suggest
  # one end of it.
  defp grade_tint(_neutral),
    do:
      "bg-slate-100 text-slate-800 ring-1 ring-slate-200 dark:bg-slate-800 dark:text-slate-100 dark:ring-slate-700"

  @doc "A short state label for the check badge on a card."
  def check_state_label(nil), do: nil
  def check_state_label(%Check{status: "pending"}), do: gettext("Queued")
  def check_state_label(%Check{status: "running"}), do: gettext("Reviewing")
  def check_state_label(%Check{status: "done"}), do: gettext("Reviewed")
  def check_state_label(%Check{status: "failed"}), do: gettext("Review failed")
  def check_state_label(%Check{}), do: nil
end
