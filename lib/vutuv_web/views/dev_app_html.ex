defmodule VutuvWeb.DevAppHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../templates/dev_app/*")
end
