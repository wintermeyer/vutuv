defmodule VutuvWeb.PhoneNumberHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  embed_templates("../templates/phone_number/*")
end
