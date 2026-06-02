defmodule VutuvWeb.FolloweeController do
  use VutuvWeb, :controller
  alias Vutuv.Pages
  alias Vutuv.Social.Connection

  def index(conn, _params) do
    total = VutuvWeb.UserHelpers.followee_count(conn.assigns[:user])

    query =
      Connection.latest(100)
      |> Pages.paginate(conn.params, total)

    user =
      conn.assigns[:user]
      |> Repo.preload([:followees, followee_connections: {query, [:followee]}])

    render(conn, "index.html", user: user, total_followees: total)
  end
end
