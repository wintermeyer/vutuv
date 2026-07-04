defmodule VutuvWeb.ExportController do
  @moduledoc """
  The member's export corner at `/:slug/export` (issue #841): `index` is the
  overview page offering the formatted CV / Lebenslauf (rendered by
  `VutuvWeb.CVController`) beside the GDPR personal-data download;
  `download` sends that `Vutuv.Export` JSON file, attachment-disposed.

  Owner-only via `AuthUser` (the route resolves `:user` through the
  `:user_pipe`); everyone else gets the 403 page.
  """

  use VutuvWeb, :controller

  plug(VutuvWeb.Plug.RequireLogin)
  plug(VutuvWeb.Plug.AuthUser)

  def index(conn, _params) do
    user = conn.assigns[:user]
    render(conn, "index.html", user: user, page_title: gettext("Export"))
  end

  def download(conn, _params) do
    user = conn.assigns[:user]
    json = user |> Vutuv.Export.build() |> Jason.encode!(pretty: true)

    filename = "vutuv-export-#{user.username}-#{Date.utc_today()}.json"

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(200, json)
  end
end
