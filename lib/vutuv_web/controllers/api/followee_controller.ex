defmodule VutuvWeb.Api.FolloweeController do
  use VutuvWeb, :controller

  def index(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload([:followees])

    render(conn, "index.json", followees: user.followees)
  end
end
