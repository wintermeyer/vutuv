defmodule VutuvWeb.PublicReportHTML do
  @moduledoc false
  use VutuvWeb, :html

  alias VutuvWeb.ReportHTML

  embed_templates("../templates/public_report/*")

  @doc """
  The category labels and hints are the in-app form's, so the two forms cannot
  describe the same complaint differently. The two sentences they also share —
  the good-faith declaration and the house-rules line — come from the same
  module as `<ReportHTML.good_faith_declaration>` and
  `<ReportHTML.honest_reporting_note>`.
  """
  defdelegate category_label(category), to: ReportHTML
  defdelegate category_hint(category), to: ReportHTML
end
