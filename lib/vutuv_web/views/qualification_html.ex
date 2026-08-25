defmodule VutuvWeb.QualificationHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers
  import VutuvWeb.WorkExperienceHTML, only: [employer_name: 1]

  alias Vutuv.BerlinTime
  alias Vutuv.Profiles.Qualification
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.QualificationDocument
  alias VutuvWeb.WorkExperienceHTML

  @doc "The singular name of a kind, for the form picker and the row badge."
  def kind_name("certification"), do: gettext("Certificate")
  def kind_name("license"), do: gettext("License")

  @doc "A kind's group heading on the list renderings (plural)."
  def kind_label("certification"), do: gettext("Certificates")
  def kind_label("license"), do: gettext("Licenses")

  @doc "The `{label, value}` options for the form's kind select."
  def kind_options do
    for kind <- Qualification.kinds(), do: {kind_name(kind), kind}
  end

  @doc """
  A member's credentials as `<select>` optgroups per kind (issue #858, the job
  form's "earned this job with" picker). The issuer disambiguates same-named
  credentials ("Scrum Master (Scrum.org)").
  """
  def grouped_options(qualifications) do
    for {kind, entries} <- group_by_kind(qualifications) do
      {kind_label(kind),
       for(qualification <- entries, do: {option_label(qualification), qualification.id})}
    end
  end

  defp option_label(%Qualification{issuer: nil} = qualification), do: qualification.name

  defp option_label(qualification), do: "#{qualification.name} (#{qualification.issuer})"

  @doc """
  The award-year `<select>` options: this year back to 1920, matching the
  changeset's `awarded_year` bound (an award can't be in the future).
  """
  def award_year_options, do: BerlinTime.today().year..1920//-1

  @doc """
  The expiry-year `<select>` options: 20 years out (a credential can be valid
  for years) back to 1920, within the changeset's `expires_year` bound.
  """
  def expiry_year_options, do: (BerlinTime.today().year + 20)..1920//-1

  @doc "The month `<select>` options (translated), reused from work experience."
  defdelegate month_number_options, to: WorkExperienceHTML, as: :month_options

  @doc """
  The meta line under a credential name: issuer, awarded year, and the "valid
  until …" note, joined with middots. Any part that is blank drops out, so a
  bare-name entry renders no orphan separators.
  """
  def meta_line(qualification) do
    [
      qualification.issuer,
      awarded_text(qualification),
      valid_until_text(qualification)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  @doc ~S(The award date as `2018` or `3/2018`, nil when the member gave none.)
  def awarded_text(qualification),
    do: month_year(qualification.awarded_month, qualification.awarded_year)

  @doc ~S(The expiry date as `2026` or `3/2026`, nil for a credential that never expires.)
  def expires_text(qualification),
    do: month_year(qualification.expires_month, qualification.expires_year)

  # The one month/year rule of this page: a bare year until the member named a
  # month. Every date this module shows (awarded, expires, last used) reads the
  # same because they all come through here.
  defp month_year(_month, nil), do: nil
  defp month_year(nil, year), do: Integer.to_string(year)
  defp month_year(month, year), do: "#{month}/#{year}"

  # "valid until 2026" (year) or "valid until 3/2026" (month + year).
  defp valid_until_text(qualification) do
    case expires_text(qualification) do
      nil -> nil
      date -> gettext("valid until %{date}", date: date)
    end
  end

  @doc "Whether this member has both a certificate and a licence to tab between."
  def mixed_kinds?(qualifications) do
    kinds = qualifications |> Enum.map(& &1.kind) |> Enum.uniq()
    "certification" in kinds and "license" in kinds
  end

  @doc "The `{value, label}` tabs for the profile card's kind filter."
  def tabs do
    [{"all", gettext("All")} | for(kind <- Qualification.kinds(), do: {kind, kind_label(kind)})]
  end

  @doc "The profile card's entries narrowed to the selected tab (issue #859)."
  def tab_entries(qualifications, "certification"),
    do: Enum.filter(qualifications, &(&1.kind == "certification"))

  def tab_entries(qualifications, "license"),
    do: Enum.filter(qualifications, &(&1.kind == "license"))

  def tab_entries(qualifications, _all), do: qualifications

  @doc "The class for a tab button, brand-filled when it is the active tab."
  def tab_class(true),
    do:
      "rounded-md bg-white px-3 py-1 font-semibold text-brand-700 shadow-sm dark:bg-slate-900 dark:text-brand-100"

  def tab_class(false),
    do:
      "rounded-md px-3 py-1 font-medium text-slate-600 hover:text-slate-900 dark:text-slate-400 dark:hover:text-slate-100"

  @doc """
  The list split into its kinds — `{kind, entries}` pairs in `Qualification.kinds/0`
  order, empty kinds dropped, the given order kept within each. Mirrors
  `Education.group_by_kind/1` so the section page reads the same way.
  """
  def group_by_kind(qualifications) do
    groups = Enum.group_by(qualifications, & &1.kind)

    for kind <- Qualification.kinds(), entries = groups[kind], do: {kind, entries}
  end

  defdelegate expired?(qualification), to: Qualification

  defp usage_count_text(usage) do
    ngettext("Used for %{formatted} job", "Used for %{formatted} jobs", usage.count,
      formatted: compact_count(usage.count)
    )
  end

  @doc """
  Whether the credential is still earning its keep (issue #1005): the emerald
  "Currently in use" pill while any citing job is ongoing, otherwise the calm
  "Last used: 9/2019" one. Renders nothing when neither applies, so it drops in
  wherever a `Qualification.job_usage/1` map is at hand — the list rows and the
  credential's own page share this one rendering.
  """
  attr(:usage, :map, required: true)

  def usage_status_pill(assigns) do
    ~H"""
    <.pill :if={@usage.current?} tone={:positive} data-usage-current>
      {gettext("Currently in use")}
    </.pill>
    <.pill :if={not @usage.current? and @usage.last_end != nil} tone={:neutral} data-usage-last>
      {gettext("Last used: %{date}", date: end_text(@usage.last_end))}
    </.pill>
    """
  end

  @doc """
  The small status pill this page's markings all wear: the usage badges, the
  "Expired" marker and the document's "Being reviewed" note. One shell, four
  tones, so a pill on the list row and the same pill on the entry page cannot
  drift apart — which is exactly what six hand-copied class strings had started
  to do. Extra attributes (the `data-*` test hooks) pass straight through.
  """
  attr(:tone, :atom, default: :neutral, values: [:brand, :positive, :neutral, :warning])
  attr(:class, :any, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def pill(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex items-center rounded-lg px-2 py-0.5 text-xs font-medium",
        pill_tone(@tone),
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  # Brand tint for a plain count, emerald for the reserved active/verified
  # signal, slate for a calm past fact, amber for moderation limbo (never for a
  # past fact — amber is reserved for moderation).
  defp pill_tone(:brand),
    do: "bg-brand-50 text-brand-700 dark:bg-brand-900/40 dark:text-brand-100"

  defp pill_tone(:positive),
    do: "bg-emerald-50 text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-300"

  defp pill_tone(:neutral),
    do: "bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-400"

  defp pill_tone(:warning),
    do: "bg-amber-50 text-amber-800 dark:bg-amber-900/30 dark:text-amber-200"

  # `job_usage/1` reports the last end as a `{year, month}` pair.
  defp end_text({year, month}), do: month_year(month, year)

  @doc """
  The jobs a member earned with this credential (issue #1109) — the reverse of
  each role's own "With qualification: …" line, and what the count badge on the
  list rows only summarised. Every row links the role's page, and an employer
  that is a verified organization page links there too, so the credential is a
  hub rather than a dead end. Ongoing roles come first (the
  `Qualification.citing_jobs_detail_preload/0` order).

  Renders nothing when no job cites the credential — and, since it asks
  `Qualification.job_usage/1`, nothing on a surface that did not preload the
  citing jobs either.
  """
  attr(:user, :any, required: true)
  attr(:qualification, :any, required: true)

  def citing_jobs(assigns) do
    assigns = assign(assigns, :usage, Qualification.job_usage(assigns.qualification))

    ~H"""
    <div :if={@usage} class="mt-6">
      <div class="flex flex-wrap items-center gap-2" data-qualification-usage>
        <h2 class="card__label mb-0">{pgettext("qualification detail", "Jobs")}</h2>
        <.usage_status_pill usage={@usage} />
      </div>
      <ul
        class="mt-2 divide-y divide-slate-200 overflow-hidden rounded-xl ring-1 ring-slate-200 dark:divide-slate-800 dark:ring-slate-800"
        data-citing-jobs
      >
        <li :for={job <- @qualification.work_experiences} class="px-3 py-2.5">
          <.link
            href={~p"/#{@user}/work_experiences/#{job}"}
            class="block font-semibold text-slate-900 hover:text-brand-700 dark:text-white dark:hover:text-brand-400"
          >
            {job.title}
          </.link>
          <p class="mb-0 text-sm text-slate-600 dark:text-slate-400">
            <.employer_name
              organization={WorkExperience.linked_organization(job)}
              text={job.organization}
            />
            {job_facts(job)}
          </p>
        </li>
      </ul>
    </div>
    """
  end

  # What still fits on a row's meta line beside the employer. Joined into one
  # string rather than rendered per fact — adjacent HEEx elements carry no
  # whitespace between them, so a span per fact glues "10/2024· Internship".
  defp job_facts(job) do
    case Enum.reject([job_period(job), WorkExperienceHTML.kind_note(job)], &is_nil/1) do
      [] -> nil
      facts -> "· " <> Enum.join(facts, " · ")
    end
  end

  # An entry with no dates at all has no period — `format_duration/4` would
  # read that as "Present", which is a claim the member never made.
  defp job_period(%{start_year: nil, end_year: nil}), do: nil

  defp job_period(job) do
    job.start_month
    |> WorkExperienceHTML.format_duration(job.start_year, job.end_month, job.end_year)
    |> IO.iodata_to_binary()
  end

  @doc """
  Whether this viewer gets the document block: everyone once the AI scan
  released it, the owner already during the limbo (with the pending pill).
  """
  def show_document?(qualification, as_owner?) do
    Qualification.document?(qualification) and
      (Qualification.document_released?(qualification) or as_owner?)
  end

  @doc "The thumbnail URL of the stored proof document (immutable, fingerprinted)."
  def document_thumb_url(user, qualification) do
    file = "thumb-#{qualification.document_fingerprint}.avif"
    ~p"/#{user}/qualifications/#{qualification}/document/#{file}"
  end

  @doc "The proof document itself (inline view); pass `dl: true` for the attachment download."
  def document_url(user, qualification, opts \\ []) do
    file =
      qualification.document_fingerprint <>
        QualificationDocument.public_ext(qualification.document_content_type)

    url = ~p"/#{user}/qualifications/#{qualification}/document/#{file}"
    if opts[:dl], do: url <> "?dl=1", else: url
  end

  @doc ~S(The document's short fact label: "PDF · 1.2 MB" / German "1,2 MB".)
  def document_label(qualification) do
    [document_type_word(qualification), file_size_label(qualification.document_size)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp document_type_word(%{document_content_type: "application/pdf"}), do: "PDF"
  defp document_type_word(_qualification), do: gettext("Image")

  # KB below 1 MB, else MB with one decimal — decimal comma under German, the
  # `delimited_count/1` locale convention.
  defp file_size_label(nil), do: nil

  defp file_size_label(bytes) when bytes < 1_000_000, do: "#{max(div(bytes, 1000), 1)} KB"

  defp file_size_label(bytes) do
    tenths = div(bytes, 100_000)
    separator = if Gettext.get_locale(VutuvWeb.Gettext) in ~w(de it), do: ",", else: "."
    "#{div(tenths, 10)}#{separator}#{rem(tenths, 10)} MB"
  end

  @doc """
  The proof-document block on a list row: the thumbnail (linking to the
  document itself) plus, for the owner while the AI scan still checks it, the
  amber limbo pill. Render behind `show_document?/2`.
  """
  attr(:user, :any, required: true)
  attr(:qualification, :any, required: true)
  attr(:as_owner?, :boolean, default: false)

  def document_block(assigns) do
    ~H"""
    <div class="mt-2 flex items-start gap-3" data-document-thumb>
      <a
        href={document_url(@user, @qualification)}
        target="_blank"
        rel="noopener noreferrer"
        title={gettext("View the uploaded proof (%{label})", label: document_label(@qualification))}
        class="block shrink-0 overflow-hidden rounded-lg ring-1 ring-slate-200 hover:ring-brand-400 dark:ring-slate-700"
      >
        <img
          src={document_thumb_url(@user, @qualification)}
          alt={gettext("Uploaded proof for %{name}", name: @qualification.name)}
          loading="lazy"
          class="h-20 w-auto max-w-[8rem] object-cover"
        />
      </a>
      <div class="min-w-0 text-sm">
        <a
          href={document_url(@user, @qualification, dl: true)}
          class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
        >
          {gettext("Download")}
        </a>
        <span class="block text-xs text-slate-600 dark:text-slate-400">
          {document_label(@qualification)}
        </span>
        <.pill
          :if={@as_owner? and not Qualification.document_released?(@qualification)}
          tone={:warning}
          class="mt-1"
          data-document-pending
        >
          {gettext("Being reviewed")}
        </.pill>
      </div>
    </div>
    """
  end

  @doc """
  One credential's row body (glyph + name link + owner "Expired" badge + the
  issuer/date meta line + the verification "Proof" link), shared by the profile
  card and the section `card_list` so both read the same. The caller supplies
  the wrapping `<li>` and, on the management pages, the trailing `<.row_actions>`.
  """
  attr(:user, :any, required: true)
  attr(:qualification, :any, required: true)
  attr(:as_owner?, :boolean, default: false)

  def qualification_row(assigns) do
    assigns =
      assigns
      |> assign(:meta, meta_line(assigns.qualification))
      |> assign(:usage, Qualification.job_usage(assigns.qualification))

    ~H"""
    <.qualification_glyph class="mt-0.5 h-5 w-5 shrink-0 text-slate-400 dark:text-slate-500" />
    <div class="min-w-0 flex-1">
      <.link
        href={~p"/#{@user}/qualifications/#{@qualification}"}
        class="font-medium text-slate-900 hover:text-brand-700 dark:hover:text-brand-300 dark:text-white"
      >
        {@qualification.name}
      </.link>
      <.pill :if={@as_owner? and expired?(@qualification)} class="ml-2" data-expired>
        {gettext("Expired")}
      </.pill>
      <p :if={@meta != ""} class="text-sm text-slate-600 dark:text-slate-400">{@meta}</p>
      <p
        :if={@usage}
        class="mt-1 flex flex-wrap items-center gap-1.5"
        data-qualification-usage
      >
        <.pill tone={:brand} data-usage-jobs>{usage_count_text(@usage)}</.pill>
        <.usage_status_pill usage={@usage} />
      </p>
      <a
        :if={@qualification.url}
        href={@qualification.url}
        target="_blank"
        rel="nofollow noopener noreferrer"
        class="mt-0.5 inline-flex items-center gap-1 text-sm font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
      >
        {gettext("Proof")}
        <span aria-hidden="true">↗</span>
      </a>
      <.document_block
        :if={show_document?(@qualification, @as_owner?)}
        user={@user}
        qualification={@qualification}
        as_owner?={@as_owner?}
      />
    </div>
    """
  end

  @doc """
  The neutral "verified credential" glyph beside each entry (the Heroicons
  outline shield-check, inlined). Shared by the section list and the profile's
  card, so both read the same.
  """
  attr(:class, :string, default: "h-5 w-5")

  def qualification_glyph(assigns) do
    ~H"""
    <svg
      class={@class}
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      aria-hidden="true"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M9 12.75 11.25 15 15 9.75m-3-7.036A11.959 11.959 0 0 1 3.598 6 11.99 11.99 0 0 0 3 9.749c0 5.592 3.824 10.29 9 11.623 5.176-1.332 9-6.03 9-11.622 0-1.31-.21-2.571-.598-3.751h-.152c-3.196 0-6.1-1.248-8.25-3.285Z"
      />
    </svg>
    """
  end

  embed_templates("../templates/qualification/*")
end
