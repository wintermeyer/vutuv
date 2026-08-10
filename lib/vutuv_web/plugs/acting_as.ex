defmodule VutuvWeb.Plug.ActingAs do
  @moduledoc """
  Resolves which identity the member is currently acting as (issue #1335) and
  assigns `:acting_as` — an `%Vutuv.Organizations.Organization{}` while they are
  switched into one, `nil` while they are themselves.

  Runs after `VutuvWeb.Plug.ConfigureSession`, which decides *who* they are;
  this decides *as whom they are speaking*.

  **The session's `acting_as_organization_id` is a hint, never a credential.**
  It is signed but not encrypted and valid for days, so a captured payload
  replays — the trap #1034 and #1036 already cost this app twice. Every request
  therefore re-asks `organization_roles` through
  `Vutuv.Organizations.acting_organization/2` instead of trusting the value, so
  a withdrawn `publisher` role takes effect on the very next action rather than
  at the next login. The socket side of the same decision is
  `VutuvWeb.Live.InitAssigns`.

  When the id no longer resolves the plug also **drops it from the session**, so
  the member is not left with a stale mode that silently does nothing: their
  next page is plainly their own again.
  """

  import Plug.Conn

  alias Vutuv.Organizations

  def init(opts), do: opts

  def call(conn, _opts) do
    id = get_session(conn, :acting_as_organization_id)
    organization = Organizations.acting_organization(conn.assigns[:current_user], id)

    conn
    |> assign(:acting_as, organization)
    |> clear_stale(id, organization)
  end

  defp clear_stale(conn, id, nil) when is_binary(id),
    do: delete_session(conn, :acting_as_organization_id)

  defp clear_stale(conn, _id, _organization), do: conn
end
