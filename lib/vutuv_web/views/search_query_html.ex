defmodule VutuvWeb.SearchQueryHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  embed_templates("../templates/search_query/*")
end
