defmodule VutuvWeb.Admin.ApiAppHTML do
  @moduledoc false
  use VutuvWeb, :html

  import VutuvWeb.UserHelpers, only: [full_name: 1]

  embed_templates("../../templates/admin/api_app/*")
end
