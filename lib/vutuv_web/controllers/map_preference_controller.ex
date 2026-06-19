defmodule VutuvWeb.MapPreferenceController do
  @moduledoc """
  The "make this my default map" promotion: when a logged-in member clicks a
  non-default map service on an address (profile page), the `MapLinks`
  enhancement in `app.js` fires a `keepalive` POST here while the map opens in a
  new tab, so their default follows their last choice. The map links are real
  `<a>` tags, so this is pure progressive enhancement: with JS off the links
  still open, the default just does not move.

  Logged-in only, and nothing is trusted from params beyond the service name,
  which `Accounts.set_default_map_service/2` validates against the known set
  (an unknown value is simply ignored). The response is an empty 204: the
  enhancement is fire-and-forget, the map already opened.
  """
  use VutuvWeb, :controller

  alias Vutuv.Accounts

  plug(VutuvWeb.Plug.RequireLoginOr404)

  def update(conn, %{"service" => service}) do
    Accounts.set_default_map_service(conn.assigns.current_user, service)
    send_resp(conn, :no_content, "")
  end
end
