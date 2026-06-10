defmodule VutuvWeb.SlugHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  embed_templates("../templates/slug/*")
end
