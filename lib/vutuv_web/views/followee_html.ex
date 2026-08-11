defmodule VutuvWeb.FolloweeHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  # The "Organizations" section renders the pages this member follows in the
  # same row shape /settings/organizations uses, so a page reads the same
  # wherever it is listed.
  import VutuvWeb.OrganizationComponents, only: [organization_logo: 1, organization_location: 1]

  embed_templates("../templates/followee/*")
end
