defmodule VutuvWeb.UserTagHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  embed_templates("../templates/user_tag/*")
end
