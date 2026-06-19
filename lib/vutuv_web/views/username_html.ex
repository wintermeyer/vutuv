defmodule VutuvWeb.UsernameHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  embed_templates("../templates/username/*")
end
