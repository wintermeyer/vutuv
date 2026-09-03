defmodule VutuvWeb.WelcomeHTML do
  @moduledoc false
  use VutuvWeb, :html

  import VutuvWeb.WelcomeComponents

  embed_templates("../templates/welcome/*")
end
