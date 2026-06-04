defmodule VutuvWeb.FolloweeController do
  use VutuvWeb, :controller
  alias Vutuv.Pages
  alias Vutuv.Social.Connection

  def index(conn, _params) do
    total = Vutuv.Social.followee_count(conn.assigns[:user])

    query =
      Connection.latest(100)
      |> Pages.paginate(conn.params, total)

    user =
      conn.assigns[:user]
      |> Repo.preload(followee_connections: {query, [:followee]})

    # Render only the current page of followees (the paginated connections),
    # not the full :followees association.
    followees = Enum.map(user.followee_connections, & &1.followee)

    render(conn, "index.html",
      user: user,
      followees: followees,
      total_followees: total,
      work_info_by_id: VutuvWeb.UserHelpers.work_information_map(followees, 45),
      following_by_id: VutuvWeb.UserHelpers.following_map(conn.assigns[:current_user], followees)
    )
  end
end
