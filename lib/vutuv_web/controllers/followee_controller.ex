defmodule VutuvWeb.FolloweeController do
  use VutuvWeb, :controller

  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.ListDocs

  # Also served as Markdown / text / JSON via VutuvWeb.AgentDocs.ListDocs
  # (keep index.html and the doc builder in sync, see
  # agent_docs_drift_test.exs). The list itself is viewer-independent.
  def index(conn, _params) do
    # Render only the current page of followees, not the full association —
    # the pagination lives in Vutuv.Social.follows_page/3 (shared with the
    # follower list).
    %{user: user, users: followees, total: total} =
      Vutuv.Social.follows_page(conn.assigns[:user], :followees, conn.params)

    work_info_by_id = VutuvWeb.UserHelpers.work_information_map(followees, 45)

    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "index.html",
          user: user,
          followees: followees,
          total_followees: total,
          work_info_by_id: work_info_by_id,
          following_by_id:
            VutuvWeb.UserHelpers.following_map(conn.assigns[:current_user], followees),
          # The per-row mute toggle is the owner's lever over their own feed, so
          # it shows only on the owner's own "Following" list. follow_id comes
          # from following_by_id; this adds the muted state for each row.
          muted_by_id: muted_by_id(conn.assigns[:current_user], user, followees)
        )
      end,
      doc: fn ->
        ListDocs.build_follow_list(user, :following, followees, total, work_info_by_id)
      end
    )
  end

  # Only the owner viewing their own list gets the mute toggle; for anyone else
  # an empty map means no toggle renders. Returns `followee_id => muted?`.
  defp muted_by_id(%{id: id} = current_user, %{id: id}, followees) do
    current_user.id
    |> Vutuv.Social.follow_edges(Enum.map(followees, & &1.id))
    |> Map.new(fn {followee_id, edge} -> {followee_id, edge.muted?} end)
  end

  defp muted_by_id(_current_user, _user, _followees), do: %{}
end
