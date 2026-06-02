defmodule VutuvWeb.FollowerController do
  use VutuvWeb, :controller
  alias Vutuv.Pages
  alias Vutuv.Social.Connection

  def index(conn, _params) do
    total = VutuvWeb.UserHelpers.follower_count(conn.assigns[:user])

    query =
      Connection.latest(100)
      |> Pages.paginate(conn.params, total)

    user =
      conn.assigns[:user]
      |> Repo.preload([:followers, follower_connections: {query, [:follower]}])

    render(conn, "index.html", user: user, total_followers: total)
  end
end
