defmodule VutuvWeb.EducationHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers
  # The month select options, the date-range formatter and the profile card's
  # "N more entries" line are identical to a work experience's; reuse them
  # rather than duplicate the logic. The pin helpers (pinned_entry/2,
  # pin_star/1, headline_pin_controls/1) come from VutuvWeb.UserHelpers, shared
  # with the work-experience list.
  import VutuvWeb.WorkExperienceHTML,
    only: [month_options: 0, format_duration: 4, format_duration: 5, hidden_note: 1]

  alias Vutuv.Profiles.Education

  defdelegate group_by_kind(educations), to: Education

  # Every category previews the same three entries. Three because that is what
  # the whole card used to show, so no profile shows less than before; per
  # category because one shared budget starves whatever sorts last — a member
  # whose three newest rows are all Hochschulbildung lost their Ausbildung from
  # the card outright, heading and all (3 of the 73 members with a CV in the
  # dev copy, 2026-09). Unlike a work history there is no ranking to make
  # between these three: a Lehre is not worth less page than a Studium.
  @preview_cap 3

  @doc """
  The profile Education card's groups, in display order: one entry per non-empty
  CV category with its capped `:entries`, how many that is (`:shown`, what the
  card's footer measures itself against) and, where the cap cut something, the
  `hidden_note/1` naming what it left out. The twin of
  `VutuvWeb.WorkExperienceHTML.profile_groups/1`, which cuts blocks of clustered
  roles where this one cuts plain rows.
  """
  def profile_groups(educations) do
    for {kind, entries} <- group_by_kind(educations) do
      shown = Enum.take(entries, @preview_cap)

      %{
        kind: kind,
        entries: shown,
        shown: length(shown),
        hidden: hidden_note(Enum.drop(entries, @preview_cap))
      }
    end
  end

  @doc """
  A category's label (issue #849) — one wording for the form's picker, the
  entry show page and the group headings alike (unlike the work-experience
  kinds, the same term reads naturally in all three places).
  """
  def kind_label("university"), do: gettext("Higher Education")
  def kind_label("apprenticeship"), do: gettext("Vocational Training")
  def kind_label("school"), do: gettext("School Education")

  @doc "The `{label, value}` options for the form's category select."
  def kind_options do
    for kind <- Education.kinds(), do: {kind_label(kind), kind}
  end

  @doc """
  Category headings appear only once a non-university entry exists — the
  common degrees-only member keeps the familiar single unlabeled list.
  """
  def show_kind_headings?(educations) do
    Enum.any?(educations, &(&1.kind != "university"))
  end

  embed_templates("../templates/education/*")
end
