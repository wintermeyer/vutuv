defmodule VutuvWeb.Admin.TagHTML do
  @moduledoc false
  use VutuvWeb, :html

  # full_name/1 for the honor tag's member roster on the show page.
  import VutuvWeb.UserHelpers

  embed_templates("../../templates/admin/tag/*")
end
