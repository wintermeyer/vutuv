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

  @doc "The reported categories of a case, deduplicated, human-readable."
  def category_names(%Case{reports: reports}) when is_list(reports) do
    reports
    |> Enum.map(&VutuvWeb.ReportHTML.category_label(&1.category))
    |> Enum.uniq()
    |> Enum.join(", ")
  end
end
