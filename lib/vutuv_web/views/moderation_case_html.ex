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

  # These two said what became of the content as well — "the content stays
  # hidden", "the content is visible again" — and neither is a function of the
  # status: an upheld picture case deletes, an upheld post stays frozen, an
  # upheld profile comes back on the strike ladder (issue #2067). They name the
  # ruling now; `content_fate_line/1` below is the sentence beside them, its own
  # paragraph rather than a second half glued on, because two translated halves
  # of one sentence is the shape this project forbids.
  def status_line(%Case{status: "upheld"}), do: gettext("An admin confirmed the report.")
  def status_line(%Case{status: "rejected"}), do: gettext("An admin dismissed the report.")

  @doc """
  What became of the content, for a settled case — the owner's half of what
  `Moderation.reported_content_fate/1` tells the reporter, so the two sides of
  one case cannot describe it differently.
  """
  def content_fate_line(:removed), do: gettext("The content is deleted.")
  def content_fate_line(:hidden), do: gettext("The content stays hidden.")
  def content_fate_line(:visible), do: gettext("The content is visible again.")

  @doc """
  The reported categories, human-readable. Takes the statement of reasons
  (`Vutuv.Moderation.owner_notice/1`) rather than the case, so the page and
  the owner's email name the same categories in the same order.
  """
  def category_names(%{categories: categories}),
    do: Enum.map_join(categories, ", ", &VutuvWeb.ReportHTML.category_label/1)
end
