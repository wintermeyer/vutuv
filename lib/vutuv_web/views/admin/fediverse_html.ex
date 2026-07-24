defmodule VutuvWeb.Admin.FediverseHTML do
  @moduledoc false
  use VutuvWeb, :html

  import VutuvWeb.UserHelpers, only: [member_name: 1]

  embed_templates("../../templates/admin/fediverse/*")
end
