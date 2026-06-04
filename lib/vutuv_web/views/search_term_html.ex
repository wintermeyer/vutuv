defmodule VutuvWeb.SearchTermHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  embed_templates("../templates/search_term/*")
end
