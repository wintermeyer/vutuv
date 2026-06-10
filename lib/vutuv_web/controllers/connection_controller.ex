defmodule VutuvWeb.ConnectionController do
  @moduledoc """
  The mutual-connection lifecycle at the request boundary: request (`create`),
  `accept`, `decline` and `delete` (withdraw / disconnect), plus the
  profile-scoped connections page (`index`).

  Every write goes through `Vutuv.Social`, which scopes each action to the
  session user — a request cannot forge or act on someone else's connection.
  """

  use VutuvWeb, :controller

  alias Vutuv.Accounts.User
  alias Vutuv.Social
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.ListDocs
  alias VutuvWeb.ControllerHelpers

  plug(VutuvWeb.Plug.RequireLoginOr404 when action in [:create, :accept, :decline, :delete])
  plug(:scrub_params, "connection" when action in [:create])

  # The profile-scoped page (/:slug/connections): that user's accepted
  # connections (public), plus — for the owner viewing their own — the pending
  # requests addressed to them (accept/decline) and the ones they sent.
  # Also served as Markdown / text / JSON via VutuvWeb.AgentDocs.ListDocs;
  # the docs carry only the public part (accepted connections), never the
  # owner's pending requests.
  def index(conn, _params) do
    profile = conn.assigns[:user]
    current = conn.assigns[:current_user]
    owner? = current != nil and current.id == profile.id

    connections = Social.list_connections(profile)
    users = Enum.map(connections, & &1.user)
    # list_connections/1 is unpaginated, so the loaded list is the full set —
    # no separate count query needed.
    total = length(connections)
    work_info_by_id = VutuvWeb.UserHelpers.work_information_map(users, 45)

    AgentDocs.respond(conn,
      html: fn conn ->
        {incoming, outgoing} =
          if owner? do
            {Social.list_incoming_requests(current), Social.list_outgoing_requests(current)}
          else
            {[], []}
          end

        render(conn, "index.html",
          user: profile,
          owner?: owner?,
          connections: connections,
          total: total,
          incoming: incoming,
          outgoing: outgoing,
          work_info_by_id: work_info_by_id
        )
      end,
      doc: fn ->
        ListDocs.build_follow_list(profile, :connections, users, total, work_info_by_id)
      end
    )
  end

  def create(conn, %{"connection" => %{"user_id" => target_id}}) do
    case Vutuv.Repo.get(User, target_id) do
      %User{} = target -> handle_request(conn, target)
      _ -> redirect_back(conn, gettext("Something went wrong"), :error)
    end
  end

  defp handle_request(conn, target) do
    case Social.request_connection(conn.assigns.current_user, target) do
      {:ok, %{status: "accepted"}} ->
        redirect_back(conn, gettext("You are now connected."))

      {:ok, _} ->
        redirect_back(conn, gettext("Connection request sent."))

      {:error, :already_connected} ->
        redirect_back(conn, gettext("You are already connected."))

      {:error, :already_requested} ->
        redirect_back(conn, gettext("Your request is still pending."))

      {:error, :cooldown} ->
        redirect_back(conn, gettext("You cannot send this request again yet."), :error)

      {:error, _} ->
        redirect_back(conn, gettext("Something went wrong"), :error)
    end
  end

  def accept(conn, %{"id" => id}) do
    case Social.accept_connection(conn.assigns.current_user, id) do
      {:ok, _} -> redirect_back(conn, gettext("Connection accepted."))
      {:error, _} -> redirect_back(conn, gettext("Something went wrong"), :error)
    end
  end

  def decline(conn, %{"id" => id}) do
    case Social.decline_connection(conn.assigns.current_user, id) do
      {:ok, _} -> redirect_back(conn, gettext("Connection request declined."))
      {:error, _} -> redirect_back(conn, gettext("Something went wrong"), :error)
    end
  end

  def delete(conn, %{"id" => id}) do
    case Social.remove_connection(conn.assigns.current_user, id) do
      {:ok, _} -> redirect_back(conn, gettext("Connection removed."))
      {:error, _} -> redirect_back(conn, gettext("Something went wrong"), :error)
    end
  end

  defp redirect_back(conn, message, level \\ :info) do
    conn
    |> put_flash(level, message)
    |> redirect(
      to: ControllerHelpers.referrer_url(conn, fallback_url(conn.assigns[:current_user]))
    )
  end

  defp fallback_url(%User{} = user), do: ~p"/#{user}"
  defp fallback_url(_), do: ~p"/"
end
