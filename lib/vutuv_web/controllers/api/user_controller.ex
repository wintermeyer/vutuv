defmodule VutuvWeb.Api.UserController do
  @moduledoc """
  Nesting-only parent for the read-only `/api/1.0/users/:user_slug/*`
  sub-resources (vcard, emails, groups, followers, work experiences, ...).

  The user collection (`GET /api/1.0/users`) and a single user
  (`GET /api/1.0/users/:slug`) are intentionally not exposed, so this
  controller defines no actions; the router declares the resource `only: []`
  purely to namespace the nested resources.
  """
  use VutuvWeb, :controller
end
