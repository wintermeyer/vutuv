defmodule VutuvWeb.LanguageHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  alias Vutuv.Languages
  alias Vutuv.Profiles.Language

  @doc "The localized name of a language code (e.g. `en` becomes `English`)."
  defdelegate language_name(code), to: Languages, as: :name

  @doc "The `{name, code}` options for the language select, sorted by name."
  defdelegate language_options, to: Languages, as: :options

  @doc """
  The word for a level, the way a CV says it ("Verhandlungssicher"). It sits
  beside the CEFR code wherever the code shows, because a bare "C1" reads like
  an exam grade to anybody who never sat one, and a member assessing
  themselves felt like a fraud claiming it.
  """
  def proficiency_word("native"), do: gettext("Native speaker")
  def proficiency_word("c2"), do: gettext("Near-native")
  def proficiency_word("c1"), do: gettext("Business fluent")
  def proficiency_word("b2"), do: gettext("Fluent")
  def proficiency_word("b1"), do: gettext("Good command")
  def proficiency_word("a2"), do: gettext("Basic knowledge")
  def proficiency_word("a1"), do: gettext("Beginner")

  @doc """
  What a member at this level can do, in the first person, after the CEFR
  self-assessment grid. The form shows it under each choice and the badge
  carries it as its hover title.
  """
  def proficiency_can_do("native"), do: gettext("The language I grew up with.")

  def proficiency_can_do("c2"),
    do: gettext("I understand virtually everything with ease and express myself precisely.")

  def proficiency_can_do("c1"),
    do: gettext("I speak spontaneously and fluently and use the language effectively at work.")

  def proficiency_can_do("b2"),
    do: gettext("A normal conversation with native speakers works without much effort.")

  def proficiency_can_do("b1"),
    do: gettext("I get by in most everyday and travel situations.")

  def proficiency_can_do("a2"),
    do: gettext("I can communicate in simple, familiar situations.")

  def proficiency_can_do("a1"),
    do: gettext("I understand and use familiar everyday expressions.")

  @doc """
  The full proficiency label (the entry show page, the CV, the import
  preview): the code and the word, or the word alone for a mother tongue.
  """
  def proficiency_label("native"), do: proficiency_word("native")

  def proficiency_label(level) when level in ~w(c2 c1 b2 b1 a2 a1),
    do: proficiency_badge(level) <> " · " <> proficiency_word(level)

  @doc """
  The bare proficiency code the agent formats carry as `level`: the mother
  tongue reads "Native"/"Muttersprache", a CEFR level shows its code.
  """
  def proficiency_badge("native"), do: gettext("Native")
  def proficiency_badge(level) when level in ~w(c2 c1 b2 b1 a2 a1), do: String.upcase(level)

  @doc "The levels in the form's order, highest first."
  def proficiencies, do: Language.proficiencies()

  @doc """
  The proficiency badge as it is actually rendered: the brand-tint pill around
  the code and its word ("C1 · Verhandlungssicher"), with the can-do sentence
  as its hover title (which is what the `cursor-help` announces).

  Three call sites wrote this span out by hand and had already drifted — the
  profile's compact language pill carried `rounded` + `px-1.5` against the
  other two's `rounded-lg` + `px-2`. That difference is real and wanted, so it
  is a `size` here rather than a class override at the call site: a padding
  utility passed in `class` does not reliably beat the base one (same layer,
  CSS source order decides, not attribute order) — the same reason `<.chip>`
  takes a size.
  """
  attr(:proficiency, :string, required: true)
  attr(:size, :string, values: ~w(md sm), default: "md")
  attr(:class, :string, default: nil)

  def proficiency_pill(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex cursor-help items-center bg-brand-50 text-xs font-medium text-brand-700 dark:bg-brand-800/60 dark:text-brand-100",
        proficiency_pill_size(@size),
        @class
      ]}
      title={proficiency_can_do(@proficiency)}
    >
      {proficiency_label(@proficiency)}
    </span>
    """
  end

  defp proficiency_pill_size("sm"), do: "rounded px-1.5 py-0.5"
  defp proficiency_pill_size(_md), do: "rounded-lg px-2 py-0.5"

  @doc """
  The neutral "language" glyph shown beside each entry (the Heroicons
  outline "language" icon, inlined). Shared by the section list and the
  profile's Languages card, so both read the same.
  """
  attr(:class, :string, default: "h-5 w-5")

  def language_glyph(assigns) do
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
        d="m10.5 21 5.25-11.25L21 21m-9-3h7.5M3 5.621a48.474 48.474 0 0 1 6-.371m0 0c1.12 0 2.233.038 3.334.114M9 5.25V3m3.334 2.364C11.176 10.658 7.69 15.08 3 17.502m9.334-12.138c.896.061 1.785.147 2.666.257m-4.589 8.495a18.023 18.023 0 0 1-3.827-5.802"
      />
    </svg>
    """
  end

  @doc """
  The small "Preferred" marker on a member's first language (issue #894): a slate
  pill, deliberately quieter than the brand proficiency badge, with the full
  phrase in its `title`. Shared by the profile card and the public section list
  so both read the same. Guard it at the call site with
  `:if={idx == 0 and length(@languages) > 1}` — the marker only means something
  once there is a choice. (The reorder tool renders the same intent as a
  `.reorder__sub` subtext, not this pill.)
  """
  def language_preferred_badge(assigns) do
    ~H"""
    <span
      class="shrink-0 inline-flex items-center rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-600 dark:bg-slate-800 dark:text-slate-300"
      title={gettext("Preferred contact language")}
    >
      {gettext("Preferred")}
    </span>
    """
  end

  embed_templates("../templates/language/*")
end
