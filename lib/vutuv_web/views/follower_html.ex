defmodule VutuvWeb.FollowerHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  embed_templates("../templates/follower/*")
end
