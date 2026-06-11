defmodule VutuvWeb.ApiV2.UserController do
  @moduledoc """
  `GET /api/2.0/users/:slug` — a member's profile doc, read through the
  authorizing user's eyes (the same visibility rules as the HTML page).
  """

  use VutuvWeb, :controller

  alias VutuvWeb.AgentDocs.ProfileDoc
  alias VutuvWeb.ApiV2
  alias VutuvWeb.ApiV2.Problem

  plug(VutuvWeb.Plug.RequireScope, "profile:read")

  def show(conn, %{"slug" => slug}) do
    viewer = conn.assigns.current_user

    case ApiV2.fetch_visible_user(slug, viewer) do
      {:ok, user} -> ApiV2.send_json(conn, ProfileDoc.build(user, viewer: viewer))
      :error -> Problem.not_found(conn)
    end
  end
end
