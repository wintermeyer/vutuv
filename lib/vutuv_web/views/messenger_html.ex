defmodule VutuvWeb.MessengerHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  embed_templates("../templates/messenger/*")
end
