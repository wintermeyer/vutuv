defmodule VutuvWeb.ApiV2.UserController do
  @moduledoc """
  `GET /api/2.0/users/:slug` — a member's profile doc, read through the
  authorizing user's eyes (the same visibility rules as the HTML page).
  """

  use VutuvWeb, :controller

  alias VutuvWeb.ApiV2

  def show(conn, %{"slug" => slug}) do
    viewer = conn.assigns.current_user

    ApiV2.with_visible_user(conn, slug, fn user ->
      ApiV2.send_json(conn, ApiV2.profile_doc(user, viewer))
    end)
  end
end
