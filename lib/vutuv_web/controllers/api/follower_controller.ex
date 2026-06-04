defmodule VutuvWeb.Api.FollowerController do
  use VutuvWeb, :controller

  def index(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload([:followers])

    render(conn, "index.json", followers: user.followers)
  end
end
