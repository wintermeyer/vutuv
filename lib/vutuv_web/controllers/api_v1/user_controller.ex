defmodule VutuvWeb.ApiV1.UserController do
  @moduledoc """
  `GET /api/v1/users/:slug` — a member's profile doc, read through the
  authorizing user's eyes (the same visibility rules as the HTML page).
  """

  use VutuvWeb, :controller

  alias VutuvWeb.AgentDocs.ProfileDoc
  alias VutuvWeb.ApiV1
  alias VutuvWeb.ApiV1.Problem

  plug(VutuvWeb.Plug.RequireScope, "profile:read")

  def show(conn, %{"slug" => slug}) do
    viewer = conn.assigns.current_user

    case ApiV1.fetch_visible_user(slug, viewer) do
      {:ok, user} -> ApiV1.send_json(conn, ProfileDoc.build(user, viewer: viewer))
      :error -> Problem.not_found(conn)
    end
  end
end
