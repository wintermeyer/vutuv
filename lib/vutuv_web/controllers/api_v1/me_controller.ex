defmodule VutuvWeb.ApiV1.MeController do
  @moduledoc """
  `GET /api/v1/me` — the authorized user's own profile, through their own
  eyes (private emails and viewer-dependent posts included).
  """

  use VutuvWeb, :controller

  alias VutuvWeb.AgentDocs.ProfileDoc

  plug(VutuvWeb.Plug.RequireScope, "profile:read")

  def show(conn, _params) do
    user = conn.assigns.current_user
    VutuvWeb.ApiV1.send_json(conn, ProfileDoc.build(user, viewer: user))
  end
end
