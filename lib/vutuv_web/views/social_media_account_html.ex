defmodule VutuvWeb.SocialMediaAccountHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  embed_templates("../templates/social_media_account/*")
end
