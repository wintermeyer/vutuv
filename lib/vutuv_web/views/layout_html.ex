defmodule VutuvWeb.LayoutHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  embed_templates("../templates/layout/*")
end
