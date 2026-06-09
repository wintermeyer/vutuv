defmodule VutuvWeb.ConnectionHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  embed_templates("../templates/connection/*")
end
