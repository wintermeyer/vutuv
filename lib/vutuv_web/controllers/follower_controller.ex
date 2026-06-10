defmodule VutuvWeb.FollowerController do
  use VutuvWeb, :controller

  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.ListDocs

  # Also served as Markdown / text / JSON via VutuvWeb.AgentDocs.ListDocs
  # (keep index.html and the doc builder in sync, see
  # agent_docs_drift_test.exs). The list itself is viewer-independent.
  def index(conn, _params) do
    # Render only the current page of followers, not the full association —
    # the pagination lives in Vutuv.Social.follows_page/3 (shared with the
    # followee list).
    %{user: user, users: followers, total: total} =
      Vutuv.Social.follows_page(conn.assigns[:user], :followers, conn.params)

    work_info_by_id = VutuvWeb.UserHelpers.work_information_map(followers, 45)

    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "index.html",
          user: user,
          followers: followers,
          total_followers: total,
          work_info_by_id: work_info_by_id,
          following_by_id:
            VutuvWeb.UserHelpers.following_map(conn.assigns[:current_user], followers)
        )
      end,
      doc: fn ->
        ListDocs.build_follow_list(user, :followers, followers, total, work_info_by_id)
      end
    )
  end
end
