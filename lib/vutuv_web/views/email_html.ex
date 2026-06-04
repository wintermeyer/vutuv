defmodule VutuvWeb.EmailHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  embed_templates("../templates/email/*.html")
end
