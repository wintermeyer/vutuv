defmodule VutuvWeb.ApiV2.NotificationController do
  @moduledoc """
  The member's notification feed (`GET /api/2.0/notifications`, cursor-
  paginated, with the unread count) and the read marker (`POST
  /api/2.0/notifications/read`). The feed is `Vutuv.Activity`'s derived
  feed: followers, endorsements, connections, replies, likes, moderation
  notices — each entry names its kind and actor.

  Notifications span the social areas, so they ride on the social scopes:
  `social:read` to read, `social:write` to mark read.
  """

  use VutuvWeb, :controller

  alias Vutuv.Activity
  alias VutuvWeb.ApiV2
  alias VutuvWeb.ApiV2.Problem

  plug(VutuvWeb.Plug.RequireScope, "social:read" when action == :index)
  plug(VutuvWeb.Plug.RequireScope, "social:write" when action == :mark_read)

  def index(conn, params) do
    me = conn.assigns.current_user

    case ApiV2.decode_cursor(params["cursor"]) do
      {:ok, cursor} ->
        page = Activity.notifications_page(me.id, cursor: cursor, limit: ApiV2.page_limit(params))

        ApiV2.send_json(conn, %{
          type: "notifications",
          unread: Activity.unread_notification_count(me.id),
          notifications: Enum.map(page.entries, &entry/1),
          more: page.more?,
          next_cursor: ApiV2.encode_cursor(page.more? && page.next_cursor)
        })

      :error ->
        Problem.send_problem(conn, 400, "Bad cursor",
          detail: "Pass the next_cursor value from a previous page, unmodified."
        )
    end
  end

  def mark_read(conn, _params) do
    Activity.mark_notifications_read(conn.assigns.current_user.id)
    send_resp(conn, 204, "")
  end

  # The derived feed item, JSON-safe: the avatar entry can be a data URI
  # placeholder or an app path — pass URLs, drop the rest.
  defp entry(item) do
    item
    |> Map.update(:actor_avatar, nil, &avatar_url/1)
    |> Map.put(:actor_slug, item[:actor_param])
    |> Map.delete(:actor_param)
  end

  defp avatar_url("data:" <> _placeholder), do: nil
  defp avatar_url("/" <> _path = path), do: VutuvWeb.AgentDocs.abs_url(path)
  defp avatar_url(other), do: other
end
