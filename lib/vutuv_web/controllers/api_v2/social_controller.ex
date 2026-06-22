defmodule VutuvWeb.ApiV2.SocialController do
  @moduledoc """
  The social graph over the API.

  Reads (`social:read`): the follower / following / connections lists
  (same doc shape as the public `.json` pages) and
  `GET /users/:slug/relationship` — the viewer's standing with that member
  (following / followed-by / connected), which the HTML profile header shows
  but no public doc carries.

  Writes (`social:write`): `PUT` / `DELETE /users/:slug/follow` (idempotent
  follow, scoped unfollow). There is no separate connection lifecycle — vernetzt
  is simply a mutual follow, so following a member who follows you back makes
  you connected. All through `Vutuv.Social`, so blocking and live notifications
  behave exactly like the website.
  """

  use VutuvWeb, :controller

  alias Vutuv.Accounts.User
  alias Vutuv.Social
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.ListDocs
  alias VutuvWeb.ApiV2
  alias VutuvWeb.ApiV2.Problem

  # ── Reads ──

  def followers(conn, %{"slug" => slug} = params), do: follow_list(conn, slug, :followers, params)

  def following(conn, %{"slug" => slug} = params), do: follow_list(conn, slug, :followees, params)

  defp follow_list(conn, slug, side, params) do
    ApiV2.with_visible_user(conn, slug, fn user ->
      %{users: people, total: total} = Social.follows_page(user, side, params)
      doc_side = if side == :followees, do: :following, else: :followers

      ApiV2.send_json(conn, ListDocs.build_follow_list(user, doc_side, people, total))
    end)
  end

  def connections(conn, %{"slug" => slug}) do
    ApiV2.with_visible_user(conn, slug, fn user ->
      # Like the public page: the member's vernetzt list (people they mutually
      # follow).
      users = user |> Social.list_connections() |> Enum.map(& &1.user)

      ApiV2.send_json(
        conn,
        ListDocs.build_follow_list(user, :connections, users, length(users))
      )
    end)
  end

  def relationship(conn, %{"slug" => slug}) do
    viewer = conn.assigns.current_user

    ApiV2.with_visible_user(conn, slug, fn
      %User{id: id} = user when id == viewer.id ->
        ApiV2.send_json(conn, %{
          type: "relationship",
          user: AgentDocs.person_ref(user),
          self: true
        })

      user ->
        following? = Social.user_follows_user?(viewer.id, user.id)
        followed_by? = Social.user_follows_user?(user.id, viewer.id)

        ApiV2.send_json(conn, %{
          type: "relationship",
          user: AgentDocs.person_ref(user),
          self: false,
          following: following?,
          followed_by: followed_by?,
          # Vernetzt is a mutual follow.
          connected: following? and followed_by?
        })
    end)
  end

  # ── Follow / unfollow ──

  def follow(conn, %{"slug" => slug}) do
    viewer = conn.assigns.current_user

    ApiV2.with_visible_user(conn, slug, fn user ->
      cond do
        user.id == viewer.id ->
          Problem.send_problem(conn, 422, "Cannot follow yourself")

        Social.user_follows_user?(viewer.id, user.id) ->
          # PUT is idempotent: already following is success, not a conflict.
          ApiV2.send_json(conn, follow_doc(user, viewer))

        true ->
          create_follow(conn, viewer, user)
      end
    end)
  end

  defp create_follow(conn, viewer, user) do
    case Social.follow(viewer, user.id) do
      {:ok, _follow} ->
        ApiV2.send_json(conn, follow_doc(user, viewer), 201)

      {:error, :blocked} ->
        Problem.blocked(conn)

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

  # ── Doc shapes ──

  defp follow_doc(user, viewer) do
    followed_by? = Social.user_follows_user?(user.id, viewer.id)

    %{
      type: "follow",
      user: AgentDocs.person_ref(user),
      following: true,
      followed_by: followed_by?,
      # A follow-back makes the pair vernetzt.
      connected: followed_by?
    }
  end
end
