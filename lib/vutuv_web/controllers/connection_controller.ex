defmodule VutuvWeb.ConnectionController do
  @moduledoc """
  The profile-scoped vernetzt page (`/:slug/connections`): the people that user
  mutually follows (vernetzt). There is no request / accept / decline any
  more — becoming vernetzt is simply a mutual follow, so this controller is
  read-only. Ending a connection is an unfollow, which the page's row action
  routes through `FollowController` (DELETE `/follows/:id`).

  Also served as Markdown / text / JSON / XML via `VutuvWeb.AgentDocs.ListDocs`;
  the docs carry the anonymous public view (the mutual-follow list).
  """

  use VutuvWeb, :controller

  alias Vutuv.Social
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.ListDocs

  def index(conn, _params) do
    profile = conn.assigns[:user]
    current = conn.assigns[:current_user]
    owner? = current != nil and current.id == profile.id

    connections = Social.list_connections(profile)
    users = Enum.map(connections, & &1.user)
    # list_connections/1 is unpaginated, so the loaded list is the full set —
    # no separate count query needed.
    total = length(connections)

    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "index.html",
          user: profile,
          owner?: owner?,
          connections: connections,
          total: total,
          work_info_by_id: VutuvWeb.UserHelpers.work_information_map(users, 45)
        )
      end,
      doc: fn ->
        ListDocs.build_follow_list(profile, :connections, users, total)
      end
    )
  end
end
