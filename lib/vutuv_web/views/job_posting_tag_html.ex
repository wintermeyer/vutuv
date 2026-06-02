defmodule VutuvWeb.JobPostingTagHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  defp resolve_priority(2), do: gettext("Important")
  defp resolve_priority(1), do: gettext("Optional")
  defp resolve_priority(0), do: gettext("Other")

  embed_templates("../templates/job_posting_tag/*")
end
