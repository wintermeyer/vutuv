defmodule VutuvWeb.FollowerController do
  use VutuvWeb, :controller

  def index(conn, _params) do
    # Render only the current page of followers, not the full association —
    # the pagination lives in Vutuv.Social.follows_page/3 (shared with the
    # followee list).
    %{user: user, users: followers, total: total} =
      Vutuv.Social.follows_page(conn.assigns[:user], :followers, conn.params)

    render(conn, "index.html",
      user: user,
      followers: followers,
      total_followers: total,
      work_info_by_id: VutuvWeb.UserHelpers.work_information_map(followers, 45),
      following_by_id: VutuvWeb.UserHelpers.following_map(conn.assigns[:current_user], followers)
    )
  end
end
