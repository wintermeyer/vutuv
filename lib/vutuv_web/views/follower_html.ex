defmodule VutuvWeb.FollowerHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  # The "Organizations" section renders the pages following this member in the
  # same row shape the Following page and /settings/organizations use.
  import VutuvWeb.OrganizationComponents, only: [organization_row: 1]

  embed_templates("../templates/follower/*")
end
