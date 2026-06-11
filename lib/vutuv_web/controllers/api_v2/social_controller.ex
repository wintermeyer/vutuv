defmodule VutuvWeb.ApiV2.SocialController do
  @moduledoc """
  The social graph over the API.

  Reads (`social:read`): the follower / following / connections lists
  (same doc shape as the public `.json` pages) and
  `GET /users/:slug/relationship` — the viewer's standing with that member
  (following / followed-by / connection state), which the HTML profile
  header shows but no public doc carries.

  Writes (`social:write`): `PUT`/`DELETE /users/:slug/follow` (idempotent
  follow, scoped unfollow) and the connection lifecycle —
  `POST /users/:slug/connection` (request; a mutual request auto-accepts),
  `POST /connections/:id/accept` / `/decline`, `DELETE /connections/:id`
  (disconnect or withdraw). All through `Vutuv.Social`, so blocking,
  cooldowns and live notifications behave exactly like the website.
  """

  use VutuvWeb, :controller

  alias Vutuv.Accounts.User
  alias Vutuv.Social
  alias Vutuv.Social.Connection
  alias Vutuv.UUIDv7
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.ListDocs
  alias VutuvWeb.ApiV2
  alias VutuvWeb.ApiV2.Problem
  alias VutuvWeb.UserHelpers

  plug(
    VutuvWeb.Plug.RequireScope,
    "social:read" when action in [:followers, :following, :connections, :relationship]
  )

  plug(
    VutuvWeb.Plug.RequireScope,
    "social:write"
    when action in [
           :follow,
           :unfollow,
           :request_connection,
           :accept_connection,
           :decline_connection,
           :remove_connection
         ]
  )

  # ── Reads ──

  def followers(conn, %{"slug" => slug} = params), do: follow_list(conn, slug, :followers, params)

  def following(conn, %{"slug" => slug} = params), do: follow_list(conn, slug, :followees, params)

  defp follow_list(conn, slug, side, params) do
    case ApiV2.fetch_visible_user(slug, conn.assigns.current_user) do
      {:ok, user} ->
        %{users: people, total: total} = Social.follows_page(user, side, params)
        doc_side = if side == :followees, do: :following, else: :followers
        work_info = UserHelpers.work_information_map(people, 45)

        ApiV2.send_json(
          conn,
          ListDocs.build_follow_list(user, doc_side, people, total, work_info)
        )

      :error ->
        Problem.not_found(conn)
    end
  end

  def connections(conn, %{"slug" => slug}) do
    case ApiV2.fetch_visible_user(slug, conn.assigns.current_user) do
      {:ok, user} ->
        # Like the public page: accepted connections only, never the
        # owner's pending requests (those are in /relationship terms).
        users = user |> Social.list_connections() |> Enum.map(& &1.user)
        work_info = UserHelpers.work_information_map(users, 45)

        ApiV2.send_json(
          conn,
          ListDocs.build_follow_list(user, :connections, users, length(users), work_info)
        )

      :error ->
        Problem.not_found(conn)
    end
  end

  def relationship(conn, %{"slug" => slug}) do
    viewer = conn.assigns.current_user

    case ApiV2.fetch_visible_user(slug, viewer) do
      {:ok, %User{id: id} = user} when id == viewer.id ->
        ApiV2.send_json(conn, %{
          type: "relationship",
          user: AgentDocs.person_ref(user),
          self: true
        })

      {:ok, user} ->
        state = Social.connection_state(viewer, user)

        ApiV2.send_json(conn, %{
          type: "relationship",
          user: AgentDocs.person_ref(user),
          self: false,
          following: Social.user_follows_user?(viewer.id, user.id),
          followed_by: Social.user_follows_user?(user.id, viewer.id),
          connection: connection_state_doc(state, viewer)
        })

      :error ->
        Problem.not_found(conn)
    end
  end

  # ── Follow / unfollow ──

  def follow(conn, %{"slug" => slug}) do
    viewer = conn.assigns.current_user

    with {:ok, user} <- ApiV2.fetch_visible_user(slug, viewer) do
      cond do
        user.id == viewer.id ->
          Problem.send_problem(conn, 422, "Cannot follow yourself")

        Social.user_follows_user?(viewer.id, user.id) ->
          # PUT is idempotent: already following is success, not a conflict.
          ApiV2.send_json(conn, follow_doc(user, viewer))

        true ->
          create_follow(conn, viewer, user)
      end
    else
      :error -> Problem.not_found(conn)
    end
  end

  defp create_follow(conn, viewer, user) do
    case Social.follow(viewer, user.id) do
      {:ok, _follow} ->
        ApiV2.send_json(conn, follow_doc(user, viewer), 201)

      {:error, :blocked} ->
        Problem.send_problem(conn, 403, "Blocked",
          detail: "A block between the two accounts prevents this."
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        Problem.validation_failed(conn, changeset)
    end
  end

  def unfollow(conn, %{"slug" => slug}) do
    viewer = conn.assigns.current_user

    with {:ok, user} <- ApiV2.fetch_visible_user(slug, viewer),
         follow_id when is_binary(follow_id) <- Social.follow_id(viewer.id, user.id) do
      Social.unfollow!(viewer.id, follow_id)
      send_resp(conn, 204, "")
    else
      _missing -> Problem.not_found(conn, "You are not following this member.")
    end
  end

  # ── Connections ──

  def request_connection(conn, %{"slug" => slug}) do
    viewer = conn.assigns.current_user

    with {:ok, user} <- ApiV2.fetch_visible_user(slug, viewer) do
      case Social.request_connection(viewer, user) do
        {:ok, %Connection{status: "accepted"} = connection} ->
          # The other side had already asked: mutual desire, accepted now.
          ApiV2.send_json(conn, connection_doc(connection, viewer))

        {:ok, %Connection{} = connection} ->
          ApiV2.send_json(conn, connection_doc(connection, viewer), 201)

        {:error, :self} ->
          Problem.send_problem(conn, 422, "Cannot connect with yourself")

        {:error, :blocked} ->
          Problem.send_problem(conn, 403, "Blocked",
            detail: "A block between the two accounts prevents this."
          )

        {:error, reason} when reason in [:already_connected, :already_requested, :cooldown] ->
          Problem.send_problem(conn, 409, "Conflict",
            detail: conflict_detail(reason),
            extra: %{reason: reason}
          )

        {:error, %Ecto.Changeset{} = changeset} ->
          Problem.validation_failed(conn, changeset)
      end
    else
      :error -> Problem.not_found(conn)
    end
  end

  def accept_connection(conn, %{"id" => id}) do
    connection_action(conn, id, &Social.accept_connection/2)
  end

  def decline_connection(conn, %{"id" => id}) do
    connection_action(conn, id, &Social.decline_connection/2)
  end

  def remove_connection(conn, %{"id" => id}) do
    viewer = conn.assigns.current_user

    with uuid when is_binary(uuid) <- UUIDv7.cast_or_nil(id),
         {:ok, _connection} <- Social.remove_connection(viewer, uuid) do
      send_resp(conn, 204, "")
    else
      _missing -> Problem.not_found(conn)
    end
  end

  defp connection_action(conn, id, fun) do
    viewer = conn.assigns.current_user

    with uuid when is_binary(uuid) <- UUIDv7.cast_or_nil(id),
         {:ok, connection} <- fun.(viewer, uuid) do
      ApiV2.send_json(conn, connection_doc(connection, viewer))
    else
      _missing -> Problem.not_found(conn)
    end
  end

  # ── Doc shapes ──

  defp follow_doc(user, viewer) do
    %{
      type: "follow",
      user: AgentDocs.person_ref(user),
      following: true,
      followed_by: Social.user_follows_user?(user.id, viewer.id)
    }
  end

  defp connection_doc(%Connection{} = connection, viewer) do
    other_id =
      if connection.user_a_id == viewer.id, do: connection.user_b_id, else: connection.user_a_id

    %{
      type: "connection",
      id: connection.id,
      status: connection.status,
      requested_by_me: connection.requested_by_id == viewer.id,
      user: AgentDocs.person_ref(Repo.get!(User, other_id))
    }
  end

  defp connection_state_doc(%{status: :none}, _viewer), do: %{status: :none, id: nil}

  defp connection_state_doc(%{status: status, connection: connection}, viewer) do
    %{
      status: status,
      id: connection && connection.id,
      requested_by_me: connection && connection.requested_by_id == viewer.id
    }
  end

  defp conflict_detail(:already_connected), do: "You are already connected."
  defp conflict_detail(:already_requested), do: "Your request is already pending."

  defp conflict_detail(:cooldown),
    do: "A declined request's cooldown has not elapsed yet. Try again later."
end
