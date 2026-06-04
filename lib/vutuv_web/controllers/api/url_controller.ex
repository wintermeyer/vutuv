defmodule VutuvWeb.Api.UrlController do
  use VutuvWeb, :controller
  alias VutuvWeb.ControllerHelpers

  def index(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload([:urls])

    render(conn, "index.json", urls: user.urls)
  end

  def show(conn, %{"id" => id}) do
    url = ControllerHelpers.get_owned!(conn, :urls, id)
    render(conn, "show.json", url: url)
  end
end
