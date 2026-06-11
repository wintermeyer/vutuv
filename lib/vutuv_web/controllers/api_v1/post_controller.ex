defmodule VutuvWeb.ApiV1.PostController do
  @moduledoc """
  Posts over the API — everything through `Vutuv.Posts`, so audiences
  (deny-model), blocking, audience locks and the live broadcasts behave
  exactly like the website.

  Reads (`posts:read`): `GET /posts/:id` (permalink doc with the viewer's
  visible replies), `GET /users/:slug/posts` (the author archive page),
  `GET /feed` (the member's timeline, cursor-paginated; the cursor is an
  opaque signed string), `GET /posts/:id/engagement` (counts + the
  viewer's own flags).

  Writes (`posts:write`): `POST /posts` (body/denials/tags like the
  composer; image upload is not part of the API yet), `POST
  /posts/:id/replies`, `PATCH /posts/:id`, `DELETE /posts/:id`, and the
  idempotent engagement switches `PUT`/`DELETE
  /posts/:id/{like,bookmark,repost}`.
  """

  use VutuvWeb, :controller

  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias VutuvWeb.AgentDocs.PostDoc
  alias VutuvWeb.ApiV1
  alias VutuvWeb.ApiV1.Problem

  plug(
    VutuvWeb.Plug.RequireScope,
    "posts:read" when action in [:show, :archive, :feed, :engagement]
  )

  plug(
    VutuvWeb.Plug.RequireScope,
    "posts:write"
    when action in [:create, :reply, :update, :delete, :engage, :disengage]
  )

  # ── Reads ──

  def show(conn, %{"id" => id}) do
    viewer = conn.assigns.current_user

    with %Post{} = post <- Posts.get_post(id),
         true <- Posts.visible_to?(post, viewer) do
      ApiV1.send_json(conn, PostDoc.build(post.user, post, viewer: viewer))
    else
      _missing_or_hidden -> Problem.not_found(conn)
    end
  end

  def archive(conn, %{"slug" => slug} = params) do
    viewer = conn.assigns.current_user

    case ApiV1.fetch_visible_user(slug, viewer) do
      {:ok, author} ->
        {entries, total} = Posts.author_posts_page(author, viewer, params)
        path = "/#{author.active_slug}/posts"
        ApiV1.send_json(conn, PostDoc.build_archive(author, path, entries, total, nil))

      :error ->
        Problem.not_found(conn)
    end
  end

  def feed(conn, params) do
    viewer = conn.assigns.current_user

    case ApiV1.decode_cursor(params["cursor"]) do
      {:ok, cursor} ->
        page = Posts.feed_page(viewer, cursor: cursor, limit: ApiV1.page_limit(params))

        ApiV1.send_json(conn, %{
          type: "feed",
          posts: Enum.map(page.entries, &feed_entry/1),
          more: page.more?,
          next_cursor: ApiV1.encode_cursor(page.more? && page.next_cursor)
        })

      :error ->
        Problem.send_problem(conn, 400, "Bad cursor",
          detail: "Pass the next_cursor value from a previous feed page, unmodified."
        )
    end
  end

  def engagement(conn, %{"id" => id}) do
    with_visible_post(conn, id, fn conn, post ->
      ApiV1.send_json(conn, engagement_doc(post, conn.assigns.current_user))
    end)
  end

  # ── Writes ──

  def create(conn, params) do
    author = conn.assigns.current_user

    case Posts.create_post(author, params) do
      {:ok, post} -> ApiV1.send_json(conn, PostDoc.build(author, post, viewer: author), 201)
      {:error, %Ecto.Changeset{} = changeset} -> Problem.validation_failed(conn, changeset)
      {:error, reason} -> post_error(conn, reason)
    end
  end

  def reply(conn, %{"id" => id} = params) do
    author = conn.assigns.current_user

    with %Post{} = parent <- Posts.get_post(id),
         true <- Posts.visible_to?(parent, author) do
      case Posts.create_reply(author, parent, params) do
        {:ok, post} -> ApiV1.send_json(conn, PostDoc.build(author, post, viewer: author), 201)
        {:error, %Ecto.Changeset{} = changeset} -> Problem.validation_failed(conn, changeset)
        {:error, reason} -> post_error(conn, reason)
      end
    else
      _missing_or_hidden -> Problem.not_found(conn)
    end
  end

  def update(conn, %{"id" => id} = params) do
    author = conn.assigns.current_user

    case Posts.get_post(author, id) do
      %Post{} = post ->
        case Posts.update_post(post, params) do
          {:ok, post} -> ApiV1.send_json(conn, PostDoc.build(author, post, viewer: author))
          {:error, %Ecto.Changeset{} = changeset} -> Problem.validation_failed(conn, changeset)
          {:error, reason} -> post_error(conn, reason)
        end

      nil ->
        Problem.not_found(conn)
    end
  end

  def delete(conn, %{"id" => id}) do
    author = conn.assigns.current_user

    case Posts.get_post(author, id) do
      %Post{} = post ->
        {:ok, _deleted} = Posts.delete_post(post)
        send_resp(conn, 204, "")

      nil ->
        Problem.not_found(conn)
    end
  end

  # PUT /posts/:id/like|bookmark|repost — idempotent on.
  def engage(conn, %{"id" => id}) do
    with_visible_post(conn, id, fn conn, post ->
      viewer = conn.assigns.current_user

      result =
        case conn.assigns.engagement do
          :like -> Posts.like_post(viewer, post)
          :bookmark -> Posts.bookmark_post(viewer, post)
          :repost -> Posts.repost_post(viewer, post)
        end

      case result do
        :ok -> ApiV1.send_json(conn, engagement_doc(post, viewer))
        {:error, reason} -> post_error(conn, reason)
      end
    end)
  end

  # DELETE /posts/:id/like|bookmark|repost — idempotent off.
  def disengage(conn, %{"id" => id}) do
    with_visible_post(conn, id, fn conn, post ->
      viewer = conn.assigns.current_user

      case conn.assigns.engagement do
        :like -> Posts.unlike_post(viewer, post)
        :bookmark -> Posts.unbookmark_post(viewer, post)
        :repost -> Posts.unrepost_post(viewer, post)
      end

      ApiV1.send_json(conn, engagement_doc(post, viewer))
    end)
  end

  # ── Internals ──

  defp with_visible_post(conn, id, fun) do
    with %Post{} = post <- Posts.get_post(id),
         true <- Posts.visible_to?(post, conn.assigns.current_user) do
      fun.(conn, post)
    else
      _missing_or_hidden -> Problem.not_found(conn)
    end
  end

  defp engagement_doc(%Post{} = post, viewer) do
    post.id
    |> Posts.post_engagement(viewer)
    |> Map.put(:type, "post_engagement")
    |> Map.put(:post_id, post.id)
  end

  defp feed_entry(%{post: post, reposted_by: reposted_by}) do
    %{
      id: post.id,
      url: VutuvWeb.AgentDocs.abs_url(Posts.path(post)),
      author: VutuvWeb.AgentDocs.person_ref(post.user),
      published_on: post.published_on,
      body_markdown: post.body,
      tags: Enum.map(post.tags, & &1.name),
      reposted_by: reposted_by && VutuvWeb.AgentDocs.person_ref(reposted_by)
    }
  end

  defp post_error(conn, :restricted) do
    Problem.send_problem(conn, 409, "Restricted post",
      detail: "Only public posts (no audience restrictions) allow this.",
      extra: %{reason: :restricted}
    )
  end

  defp post_error(conn, :visibility_locked) do
    Problem.send_problem(conn, 409, "Audience locked",
      detail: "While reposts or replies exist the audience cannot be restricted.",
      extra: %{reason: :visibility_locked}
    )
  end

  defp post_error(conn, :blocked) do
    Problem.send_problem(conn, 403, "Blocked",
      detail: "A block between the two accounts prevents this."
    )
  end

  defp post_error(conn, :not_visible), do: Problem.not_found(conn)

  defp post_error(conn, reason)
       when reason in [:invalid_denials, :invalid_images, :too_many_images] do
    Problem.send_problem(conn, 422, "Validation failed",
      detail: invalid_detail(reason),
      extra: %{reason: reason}
    )
  end

  defp invalid_detail(:invalid_denials),
    do: "The denials must name your own groups, existing users, or known wildcards."

  defp invalid_detail(:invalid_images), do: "image_ids must be your own pending uploads."
  defp invalid_detail(:too_many_images), do: "Too many images for one post."
end
