defmodule VutuvWeb.JobPostingHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  embed_templates("../templates/job_posting/*")
end
