defmodule VutuvWeb.FolloweeHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  embed_templates("../templates/followee/*")
end
