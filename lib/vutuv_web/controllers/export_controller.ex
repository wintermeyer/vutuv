defmodule VutuvWeb.ExportController do
  @moduledoc """
  The owner's personal data download (`Vutuv.Export`): one JSON file,
  attachment-disposed. Owner-only via `AuthUser` (the route resolves
  `:user` through the `:user_pipe`); everyone else gets the 403 page.
  """

  use VutuvWeb, :controller

  plug(VutuvWeb.Plug.RequireLogin)
  plug(VutuvWeb.Plug.AuthUser)

  def show(conn, _params) do
    user = conn.assigns[:user]
    json = user |> Vutuv.Export.build() |> Jason.encode!(pretty: true)

    filename = "vutuv-export-#{user.active_slug}-#{Date.utc_today()}.json"

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(200, json)
  end
end
