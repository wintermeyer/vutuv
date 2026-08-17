defmodule VutuvWeb.SocialMediaAccountHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  alias Vutuv.Profiles.SocialMediaAccount

  embed_templates("../templates/social_media_account/*")

  @doc """
  Where to put the vutuv profile URL so this provider's account can be proved
  (`Vutuv.Profiles.SocialAccountVerification`). Each network keeps its own
  sentence rather than one generic "your profile" line: the whole difficulty of
  this page is finding the right field, and Bluesky's bio and a forge's website
  field are not the same place.
  """
  def verify_instructions(provider) do
    if SocialMediaAccount.self_hosted_provider?(provider) do
      gettext(
        "Add this address to your %{provider} profile, in the website field or your description, then run the check:",
        provider: provider
      )
    else
      gettext(
        "Add this address to your Bluesky profile description (your bio), then run the check:"
      )
    end
  end
end
