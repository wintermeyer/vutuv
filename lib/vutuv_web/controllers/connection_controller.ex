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

    # Paginate like the follower / following lists (this is a public, crawlable
    # URL); the doc builder gets the same page, so the agent formats agree.
    %{connections: connections, total: total} = Social.connections_page(profile, conn.params)
    users = Enum.map(connections, & &1.user)

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
