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
  The full, descriptive proficiency label (the form select and the entry show
  page). CEFR levels carry a plain-language gloss so the code is never opaque.
  """
  def proficiency_label("native"), do: gettext("Native speaker")
  def proficiency_label("c2"), do: gettext("C2 (Proficient)")
  def proficiency_label("c1"), do: gettext("C1 (Advanced)")
  def proficiency_label("b2"), do: gettext("B2 (Upper intermediate)")
  def proficiency_label("b1"), do: gettext("B1 (Intermediate)")
  def proficiency_label("a2"), do: gettext("A2 (Elementary)")
  def proficiency_label("a1"), do: gettext("A1 (Beginner)")

  @doc """
  The compact proficiency badge shown on the profile card and CV: the mother
  tongue reads "Native"/"Muttersprache", a CEFR level shows its bare code.
  """
  def proficiency_badge("native"), do: gettext("Native")
  def proficiency_badge(level) when level in ~w(c2 c1 b2 b1 a2 a1), do: String.upcase(level)

  @doc "The `{label, value}` options for the form's proficiency select."
  def proficiency_options do
    for level <- Language.proficiencies(), do: {proficiency_label(level), level}
  end

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

  embed_templates("../templates/language/*")
end
