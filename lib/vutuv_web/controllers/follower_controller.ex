defmodule VutuvWeb.FollowerController do
  use VutuvWeb, :controller
  alias Vutuv.Pages
  alias Vutuv.Social.Follow

  def index(conn, _params) do
    total = Vutuv.Social.follower_count(conn.assigns[:user])

    query =
      Follow.latest(100)
      |> Pages.paginate(conn.params, total)

    user =
      conn.assigns[:user]
      |> Repo.preload(inbound_follows: {query, [:follower]})

    # Render only the current page of followers (the paginated follows),
    # not the full :followers association.
    followers = Enum.map(user.inbound_follows, & &1.follower)

    render(conn, "index.html",
      user: user,
      followers: followers,
      total_followers: total,
      work_info_by_id: VutuvWeb.UserHelpers.work_information_map(followers, 45),
      following_by_id: VutuvWeb.UserHelpers.following_map(conn.assigns[:current_user], followers)
    )
  end
end
