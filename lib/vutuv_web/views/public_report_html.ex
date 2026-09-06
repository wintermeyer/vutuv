defmodule VutuvWeb.PublicReportHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../templates/public_report/*")

  @doc """
  The category labels and hints are the in-app form's, so the two forms cannot
  describe the same complaint differently.
  """
  defdelegate category_label(category), to: VutuvWeb.ReportHTML
  defdelegate category_hint(category), to: VutuvWeb.ReportHTML
end
