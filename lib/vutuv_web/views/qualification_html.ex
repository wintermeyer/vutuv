defmodule VutuvWeb.QualificationHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  alias Vutuv.BerlinTime
  alias Vutuv.Profiles.Qualification

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
  defdelegate month_number_options, to: VutuvWeb.WorkExperienceHTML, as: :month_options

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

  defp awarded_text(%{awarded_year: nil}), do: nil
  defp awarded_text(%{awarded_month: nil, awarded_year: year}), do: Integer.to_string(year)
  defp awarded_text(%{awarded_month: month, awarded_year: year}), do: "#{month}/#{year}"

  # "valid until 2026" (year) or "valid until 3/2026" (month + year).
  defp valid_until_text(%{expires_year: nil}), do: nil

  defp valid_until_text(%{expires_month: nil, expires_year: year}),
    do: gettext("valid until %{date}", date: Integer.to_string(year))

  defp valid_until_text(%{expires_month: month, expires_year: year}),
    do: gettext("valid until %{date}", date: "#{month}/#{year}")

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
    assigns = assign(assigns, :meta, meta_line(assigns.qualification))

    ~H"""
    <.qualification_glyph class="mt-0.5 h-5 w-5 shrink-0 text-slate-400 dark:text-slate-500" />
    <div class="min-w-0 flex-1">
      <.link
        href={~p"/#{@user}/qualifications/#{@qualification}"}
        class="font-medium text-slate-900 hover:text-brand-700 dark:text-white"
      >
        {@qualification.name}
      </.link>
      <span
        :if={@as_owner? and expired?(@qualification)}
        class="ml-2 inline-flex items-center rounded-lg bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-600 dark:bg-slate-800 dark:text-slate-400"
      >
        {gettext("Expired")}
      </span>
      <p :if={@meta != ""} class="text-sm text-slate-600 dark:text-slate-400">{@meta}</p>
      <a
        :if={@qualification.url}
        href={@qualification.url}
        target="_blank"
        rel="nofollow noopener noreferrer"
        class="mt-0.5 inline-flex items-center gap-1 text-sm font-semibold text-brand-600 hover:text-brand-700"
      >
        {gettext("Proof")}
        <span aria-hidden="true">↗</span>
      </a>
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
