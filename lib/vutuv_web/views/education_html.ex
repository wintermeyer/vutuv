defmodule VutuvWeb.EducationHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers
  # The month select options and the date-range formatter are identical to a
  # work experience's; reuse them rather than duplicate the logic.
  import VutuvWeb.WorkExperienceHTML,
    only: [month_options: 0, format_duration: 4, format_duration: 5, pin_star: 1]

  alias Vutuv.Profiles.Education

  defdelegate group_by_kind(educations), to: Education

  @doc """
  The education a member pinned as their profile headline (issue #882), found in
  the already-loaded list, or nil when they use the automatic job resolution.
  `id` is a member's `users.profile_education_id`. The management page's chooser
  marks this entry and offers the revert.
  """
  def pinned_entry(_educations, nil), do: nil
  def pinned_entry(educations, id), do: Enum.find(educations, &(&1.id == id))

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
