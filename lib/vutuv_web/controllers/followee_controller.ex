defmodule VutuvWeb.FolloweeController do
  use VutuvWeb, :controller

  def index(conn, _params) do
    # Render only the current page of followees, not the full association —
    # the pagination lives in Vutuv.Social.follows_page/3 (shared with the
    # follower list).
    %{user: user, users: followees, total: total} =
      Vutuv.Social.follows_page(conn.assigns[:user], :followees, conn.params)

    render(conn, "index.html",
      user: user,
      followees: followees,
      total_followees: total,
      work_info_by_id: VutuvWeb.UserHelpers.work_information_map(followees, 45),
      following_by_id: VutuvWeb.UserHelpers.following_map(conn.assigns[:current_user], followees)
    )
  end
end
