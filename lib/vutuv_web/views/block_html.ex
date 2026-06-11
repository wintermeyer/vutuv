defmodule VutuvWeb.BlockHTML do
  @moduledoc false
  use VutuvWeb, :html

  import VutuvWeb.UserHelpers, only: [full_name: 1]

  embed_templates("../templates/block/*")
end
