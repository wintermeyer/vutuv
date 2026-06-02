defmodule VutuvWeb.PageHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../templates/page/*")
end
