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

    render(conn, "index.html",
      user: user,
      total_followers: total,
      work_info_by_id: VutuvWeb.UserHelpers.work_information_map(user.followers, 45),
      following_by_id:
        VutuvWeb.UserHelpers.following_map(conn.assigns[:current_user], user.followers)
    )
  end
end
