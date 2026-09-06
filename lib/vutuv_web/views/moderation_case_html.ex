defmodule VutuvWeb.ModerationCaseHTML do
  @moduledoc false
  use VutuvWeb, :html

  alias Vutuv.Moderation.Case

  embed_templates("../templates/moderation_case/*")

  @doc "What the status means, in the owner's words."
  def status_line(%Case{status: "pending_owner"}),
    do: gettext("Hidden. You can settle this yourself - see below.")

  def status_line(%Case{status: "flagged"}),
    do: gettext("Visible. Our admins will take a look.")

  def status_line(%Case{status: "escalated"}),
    do: gettext("Hidden until one of our admins has ruled. You do not need to do anything.")

  def status_line(%Case{status: "resolved_deleted"}),
    do: gettext("Settled: the content was deleted.")

  def status_line(%Case{status: "resolved_edited"}),
    do: gettext("Settled: you revised the content and it is visible again.")

  def status_line(%Case{status: "upheld"}),
    do: gettext("An admin confirmed the report. The content stays hidden.")

  def status_line(%Case{status: "rejected"}),
    do: gettext("An admin dismissed the report. The content is visible again.")

  @doc """
  The reported categories, human-readable. Takes the statement of reasons
  (`Vutuv.Moderation.owner_notice/1`) rather than the case, so the page and
  the owner's email name the same categories in the same order.
  """
  def category_names(%{categories: categories}),
    do: Enum.map_join(categories, ", ", &VutuvWeb.ReportHTML.category_label/1)
end
