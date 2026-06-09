defmodule Vutuv.Posts do
  @moduledoc """
  The Posts context: markdown posts with images, tags and deny-model
  audiences.

  **Visibility is deny-based.** A post with no denials is public (crawlable,
  visible logged-out). Each `Vutuv.Posts.PostDenial` excludes the readers
  matching one target (group / single user / wildcard); matching *any* denial
  excludes the reader. Three invariants live here, not in data:

    * the author always sees their own posts;
    * **any** denial also closes anonymous access — a logged-out reader
      cannot be proven not-denied;
    * group membership is evaluated live at read time.

  All four read paths (feed, profile, permalink, image proxy) must go through
  `visible_to?/2` or the composable `scope_visible/2` — never filter by hand.

  **Permalinks** are `/:slug/posts/:id` — the post's UUID v7 is the whole
  coordinate. `published_on` (the UTC date at insert time, never changed by
  edits) scopes the day/month/year archive index pages under the same
  `/:slug/posts` prefix.

  **Images** upload eagerly while composing (`create_pending_image/3`), so
  inline markdown can reference them before the post exists; submit attaches
  them (`image_ids`). Unattached leftovers are swept after a day.

  **Engagement**: likes, bookmarks and reposts are one row per (post, user),
  toggled idempotently; counters are counted live from the rows and every
  change broadcasts `{:post_counters, …}` on the post's topic
  (`subscribe_post/1`). Reposts work on **public** posts only, distribute
  into the reposter's followers' feeds and pin the post's audience open
  while any exist (the author can still delete).

  **Replies** (`create_reply/3`) are normal posts plus a
  `Vutuv.Posts.PostReply` row naming the parent. Only public parents accept
  replies, and replies pin the parent's audience open like reposts do. A
  reply outlives its parent: the parent references nilify on deletion, so
  the banner can degrade from a link to "a now-deleted post by X" to a
  nameless notice once the account is gone too.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.PostImageStore
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostBookmark
  alias Vutuv.Posts.PostDenial
  alias Vutuv.Posts.PostImage
  alias Vutuv.Posts.PostLike
  alias Vutuv.Posts.PostReply
  alias Vutuv.Posts.PostRepost
  alias Vutuv.Posts.PostTag
  alias Vutuv.Repo
  alias Vutuv.Social.Follow
  alias Vutuv.Social.Group
  alias Vutuv.Tags.Tag
  alias Vutuv.UUIDv7

  @default_feed_limit 20
  @default_profile_limit 3
  @default_thread_limit 100
  @pending_max_age_hours 24
  @max_tags 5

  def max_images_per_post, do: Keyword.fetch!(config(), :max_per_post)
  def max_image_filesize, do: Keyword.fetch!(config(), :max_filesize)
  def max_tags_per_post, do: @max_tags
  defp config, do: Application.fetch_env!(:vutuv, :post_images)

  ## Creating / updating / deleting

  @doc """
  Creates a post for `author`.

  Accepted attrs (atom or string keys):

    * `:body` — markdown, at most `Post.max_body_length/0` chars; may be
      blank when images are attached
    * `:denials` — list of `%{"group_id" => id}` / `%{"denied_user_id" => id}`
      / `%{"wildcard" => w}` maps (see `Vutuv.Posts.PostDenial`)
    * `:tags` — comma-separated string or list of tag names (find-or-create,
      case-insensitive; invalid values are skipped, at most
      `max_tags_per_post/0` are kept)
    * `:image_ids` — pending image ids of the author, in display order

  Returns `{:ok, post}` (preloaded), `{:error, changeset}`,
  `{:error, :invalid_denials}`, `{:error, :invalid_images}` or
  `{:error, :too_many_images}`. Broadcasts `{:new_post, %{post_id:,
  author_id:}}` to the author's and every follower's activity topic.
  """
  def create_post(%User{} = author, attrs) do
    image_ids = parse_ids(fetch(attrs, :image_ids) || [])

    with {:ok, denials} <- normalize_denials(author.id, fetch(attrs, :denials) || []),
         :ok <- check_image_count(image_ids),
         {:ok, changeset} <- build_changeset(%Post{user_id: author.id}, attrs, denials, image_ids) do
      case insert_post(changeset, image_ids) do
        {:ok, post} ->
          post = preload_post(post)
          broadcast_new_post(post)
          {:ok, post}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Creates a reply to `parent` for `author` — a normal post (same attrs,
  validations and broadcasts as `create_post/2`) plus a
  `Vutuv.Posts.PostReply` row naming the parent. Only **public** parents
  (no denials) accept replies — `{:error, :restricted}` otherwise — and the
  parent must be visible to the author (`{:error, :not_visible}`). While
  replies exist the parent's audience is pinned open, like with reposts.

  Additionally broadcasts the parent's fresh `{:post_counters, …}` on its
  post topic and notifies the parent's author (unless they reply to
  themselves). The reply outlives its parent: on parent deletion the post
  reference nilifies, on account deletion the author reference too (see
  `Vutuv.Posts.PostReply`).
  """
  def create_reply(%User{} = author, %Post{} = parent, attrs) do
    image_ids = parse_ids(fetch(attrs, :image_ids) || [])

    with :ok <- check_reply_allowed(author, parent),
         {:ok, denials} <- normalize_denials(author.id, fetch(attrs, :denials) || []),
         :ok <- check_image_count(image_ids),
         {:ok, changeset} <- build_changeset(%Post{user_id: author.id}, attrs, denials, image_ids) do
      case insert_post(changeset, image_ids, parent) do
        {:ok, post} ->
          post = preload_post(post)
          broadcast_new_post(post)
          broadcast_reply(parent, post)
          {:ok, post}

        {:error, _} = error ->
          error
      end
    end
  end

  defp check_reply_allowed(%User{} = author, %Post{} = parent) do
    cond do
      not visible_to?(parent, author) -> {:error, :not_visible}
      restricted?(parent) -> {:error, :restricted}
      true -> :ok
    end
  end

  @doc """
  Updates a post: body, denials, tags and the attached-image set are replaced
  by what `attrs` carries (same keys as `create_post/2`). Detached images are
  deleted, rows and files. The publication date (the archive coordinate)
  never changes.
  """
  def update_post(%Post{} = post, attrs) do
    post = Repo.preload(post, [:denials, :post_tags, :images])
    image_ids = parse_ids(fetch(attrs, :image_ids) || [])

    with {:ok, denials} <- normalize_denials(post.user_id, fetch(attrs, :denials) || []),
         :ok <- check_visibility_lock(post, denials),
         :ok <- check_image_count(image_ids),
         {:ok, changeset} <- build_changeset(post, attrs, denials, image_ids) do
      removed = Enum.reject(post.images, &(&1.id in image_ids))
      run_update(changeset, removed, image_ids)
    end
  end

  defp run_update(changeset, removed, image_ids) do
    case Repo.transaction(fn -> apply_update!(changeset, removed, image_ids) end) do
      {:ok, updated} ->
        # Only after the commit: a rolled-back update must not lose files.
        Enum.each(removed, &PostImageStore.delete(&1.token))
        {:ok, preload_post(updated)}

      {:error, _} = error ->
        error
    end
  end

  defp apply_update!(changeset, removed, image_ids) do
    case Repo.update(changeset) do
      {:ok, updated} ->
        if removed != [] do
          Repo.delete_all(from(i in PostImage, where: i.id in ^Enum.map(removed, & &1.id)))
        end

        attach_images!(updated, image_ids)
        updated

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  @doc """
  Deletes a post including its image files, and tells open clients it is gone:
  `{:post_deleted, …}` to the author's followers' feeds and the post's topic
  (so feed entries drop and action bars empty). When the post was a reply, its
  parent's fresh reply count is re-broadcast.
  """
  def delete_post(%Post{} = post) do
    post = Repo.preload(post, :images)
    parent_id = reply_parent_id(post.id)

    case Repo.delete(post) do
      {:ok, deleted} ->
        Enum.each(post.images, &PostImageStore.delete(&1.token))
        broadcast_post_deleted(post.id, post.user_id)
        if parent_id, do: broadcast_reply_count(parent_id)
        {:ok, deleted}

      {:error, _} = error ->
        error
    end
  end

  # Body + denials + tags in one changeset; images attach separately (they
  # are pre-existing rows, not nested params).
  defp build_changeset(post_or_struct, attrs, denials, image_ids) do
    tag_ids = attrs |> fetch(:tags) |> parse_tag_values() |> tag_ids_for()

    changeset =
      post_or_struct
      |> Post.changeset(%{body: to_string(fetch(attrs, :body) || "")})
      |> Ecto.Changeset.put_assoc(:denials, Enum.map(denials, &struct(PostDenial, &1)))
      |> Ecto.Changeset.put_assoc(:post_tags, Enum.map(tag_ids, &%PostTag{tag_id: &1}))
      |> require_content(image_ids)

    if changeset.valid?, do: {:ok, changeset}, else: {:error, changeset}
  end

  defp require_content(changeset, image_ids) do
    body = Ecto.Changeset.get_field(changeset, :body) || ""

    if String.trim(body) == "" and image_ids == [] do
      Ecto.Changeset.add_error(changeset, :body, "can't be blank")
    else
      changeset
    end
  end

  # Stamps the UTC publication date (the archive coordinate) and commits the
  # post, its image claims and — for a reply — the PostReply row in one
  # transaction, so post and reference land (or roll back) together.
  defp insert_post(changeset, image_ids, parent \\ nil) do
    Repo.transaction(fn ->
      changeset
      |> Ecto.Changeset.change(published_on: Date.utc_today())
      |> Repo.insert()
      |> case do
        {:ok, post} ->
          attach_images!(post, image_ids)
          insert_reply_ref!(post, parent)
          post

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  defp insert_reply_ref!(_post, nil), do: :ok

  defp insert_reply_ref!(%Post{} = post, %Post{} = parent) do
    Repo.insert!(%PostReply{
      post_id: post.id,
      parent_post_id: parent.id,
      parent_author_id: parent.user_id
    })
  end

  # Claims each image row for the post (ownership and pending state are
  # enforced by the WHERE, so a tampered id rolls the whole insert back).
  defp attach_images!(%Post{} = post, image_ids) do
    now = NaiveDateTime.utc_now(:second)

    image_ids
    |> Enum.with_index()
    |> Enum.each(fn {id, position} ->
      {count, _} =
        Repo.update_all(
          from(i in PostImage,
            where:
              i.id == ^id and i.user_id == ^post.user_id and
                (is_nil(i.post_id) or i.post_id == ^post.id)
          ),
          set: [post_id: post.id, position: position, updated_at: now]
        )

      if count != 1, do: Repo.rollback(:invalid_images)
    end)
  end

  defp check_image_count(image_ids) do
    if length(image_ids) > max_images_per_post(), do: {:error, :too_many_images}, else: :ok
  end

  ## Denials

  # Validates and normalizes the denial list into attr maps for PostDenial
  # structs. Groups must belong to the author; you cannot deny yourself;
  # wildcards must be known. Duplicates collapse.
  defp normalize_denials(author_id, denials) when is_list(denials) do
    denials
    |> Enum.reduce_while({:ok, []}, fn denial, {:ok, acc} ->
      case normalize_denial(author_id, denial) do
        {:ok, attrs} -> {:cont, {:ok, [attrs | acc]}}
        :error -> {:halt, {:error, :invalid_denials}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, list |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp normalize_denials(_author_id, _other), do: {:error, :invalid_denials}

  defp normalize_denial(author_id, denial) when is_map(denial) do
    targets = [
      group_id: denial |> fetch(:group_id) |> parse_id(),
      denied_user_id: denial |> fetch(:denied_user_id) |> parse_id(),
      wildcard: fetch(denial, :wildcard)
    ]

    # Exactly one target per denial (mirrors the DB check constraint).
    case Enum.reject(targets, fn {_key, value} -> is_nil(value) end) do
      [target] -> validate_denial_target(author_id, target)
      _ -> :error
    end
  end

  defp normalize_denial(_author_id, _other), do: :error

  defp validate_denial_target(author_id, {:group_id, group_id}) do
    case Repo.get(Group, group_id) do
      %Group{user_id: ^author_id} -> {:ok, %{group_id: group_id}}
      _ -> :error
    end
  end

  defp validate_denial_target(author_id, {:denied_user_id, denied_user_id}) do
    if denied_user_id != author_id &&
         Repo.exists?(from(u in User, where: u.id == ^denied_user_id)) do
      {:ok, %{denied_user_id: denied_user_id}}
    else
      :error
    end
  end

  defp validate_denial_target(_author_id, {:wildcard, wildcard}) do
    if wildcard in PostDenial.wildcards(), do: {:ok, %{wildcard: wildcard}}, else: :error
  end

  ## Visibility

  @doc """
  Whether `viewer` (a `%User{}` or `nil`) is the post's author — the one
  predicate gating the Edit/Delete affordances wherever a post renders.
  """
  def author?(%Post{user_id: author_id}, %User{id: author_id}), do: true
  def author?(%Post{}, _viewer), do: false

  @doc """
  Whether `viewer` (a `%User{}` or `nil` for anonymous) may see `post`.

  The single source of truth for post access — the permalink page, the
  image proxy and the live-feed pill all call this. List queries use the
  equivalent `scope_visible/2`.
  """
  def visible_to?(%Post{user_id: author_id}, %User{id: author_id}), do: true

  def visible_to?(%Post{} = post, nil) do
    # Anonymous readers see a post only when it has no denials at all.
    not restricted?(post)
  end

  def visible_to?(%Post{} = post, %User{id: viewer_id}) do
    not Repo.exists?(denial_match_query(post.id, post.user_id, viewer_id))
  end

  # All denial rows of the post that match this viewer (union semantics).
  defp denial_match_query(post_id, author_id, viewer_id) do
    from(d in PostDenial,
      where: d.post_id == ^post_id,
      where:
        d.denied_user_id == ^viewer_id or
          d.wildcard == "everyone" or
          (d.wildcard == "non_followers" and
             fragment(
               "NOT EXISTS (SELECT 1 FROM follows c WHERE c.follower_id = ? AND c.followee_id = ?)",
               type(^viewer_id, UUIDv7),
               type(^author_id, UUIDv7)
             )) or
          (d.wildcard == "non_followees" and
             fragment(
               "NOT EXISTS (SELECT 1 FROM follows c WHERE c.follower_id = ? AND c.followee_id = ?)",
               type(^author_id, UUIDv7),
               type(^viewer_id, UUIDv7)
             )) or
          (d.wildcard == "non_connections" and
             fragment(
               "NOT EXISTS (SELECT 1 FROM connections c WHERE c.status = 'accepted' AND ((c.user_a_id = ? AND c.user_b_id = ?) OR (c.user_a_id = ? AND c.user_b_id = ?)))",
               type(^author_id, UUIDv7),
               type(^viewer_id, UUIDv7),
               type(^viewer_id, UUIDv7),
               type(^author_id, UUIDv7)
             )) or
          (not is_nil(d.group_id) and
             fragment(
               """
               EXISTS (SELECT 1 FROM memberships m
                       JOIN follows c ON c.id = m.follow_id
                       WHERE m.group_id = ? AND c.follower_id = ? AND c.followee_id = ?)
               """,
               d.group_id,
               type(^author_id, UUIDv7),
               type(^viewer_id, UUIDv7)
             ))
    )
  end

  @doc """
  Narrows a `Post` query to what `viewer` may see — the SQL twin of
  `visible_to?/2`. Composable: `from(p in Post) |> scope_visible(viewer)`.
  """
  def scope_visible(query, nil) do
    from(p in query,
      where: fragment("NOT EXISTS (SELECT 1 FROM post_denials d WHERE d.post_id = ?)", p.id)
    )
  end

  def scope_visible(query, %User{id: viewer_id}) do
    from(p in query,
      where:
        p.user_id == ^viewer_id or
          fragment(
            """
            NOT EXISTS (
              SELECT 1 FROM post_denials d
              WHERE d.post_id = ?
                AND (
                  d.denied_user_id = ?
                  OR d.wildcard = 'everyone'
                  OR (d.wildcard = 'non_followers' AND NOT EXISTS (
                        SELECT 1 FROM follows c
                        WHERE c.follower_id = ? AND c.followee_id = ?))
                  OR (d.wildcard = 'non_followees' AND NOT EXISTS (
                        SELECT 1 FROM follows c
                        WHERE c.follower_id = ? AND c.followee_id = ?))
                  OR (d.wildcard = 'non_connections' AND NOT EXISTS (
                        SELECT 1 FROM connections c
                        WHERE c.status = 'accepted'
                          AND ((c.user_a_id = ? AND c.user_b_id = ?)
                            OR (c.user_a_id = ? AND c.user_b_id = ?))))
                  OR (d.group_id IS NOT NULL AND EXISTS (
                        SELECT 1 FROM memberships m
                        JOIN follows c ON c.id = m.follow_id
                        WHERE m.group_id = d.group_id
                          AND c.follower_id = ? AND c.followee_id = ?))
                )
            )
            """,
            p.id,
            type(^viewer_id, UUIDv7),
            type(^viewer_id, UUIDv7),
            p.user_id,
            p.user_id,
            type(^viewer_id, UUIDv7),
            p.user_id,
            type(^viewer_id, UUIDv7),
            type(^viewer_id, UUIDv7),
            p.user_id,
            p.user_id,
            type(^viewer_id, UUIDv7)
          )
    )
  end

  @doc """
  Whether the post has any audience restriction. Restricted posts are
  noindexed and hidden from anonymous visitors.
  """
  def restricted?(%Post{denials: denials}) when is_list(denials), do: denials != []

  def restricted?(%Post{id: id}) do
    Repo.exists?(from(d in PostDenial, where: d.post_id == ^id))
  end

  ## Likes, bookmarks, reposts

  # Likes/bookmarks/reposts are one row per (post, user); toggles are
  # idempotent (unique index + ON CONFLICT DO NOTHING). Every real change
  # broadcasts the post's fresh absolute counters to its topic, so open
  # action bars update live; the actor's own sessions additionally get an
  # {:engagement_changed, …} on their activity topic (multi-tab sync for
  # the likes/bookmarks pages).

  @doc "Likes `post` as `user` (idempotent). Only visible posts can be liked."
  def like_post(%User{} = user, %Post{} = post) do
    with {:ok, _} <- engage(PostLike, :like, user, post), do: :ok
  end

  @doc "Removes `user`'s like (idempotent)."
  def unlike_post(%User{} = user, %Post{} = post), do: disengage(PostLike, :like, user, post)

  @doc "Bookmarks `post` for `user` (idempotent). Only visible posts."
  def bookmark_post(%User{} = user, %Post{} = post) do
    with {:ok, _} <- engage(PostBookmark, :bookmark, user, post), do: :ok
  end

  @doc "Removes `user`'s bookmark (idempotent)."
  def unbookmark_post(%User{} = user, %Post{} = post),
    do: disengage(PostBookmark, :bookmark, user, post)

  @doc """
  Reposts `post` as `user` (idempotent). Only **public** posts (no denials)
  can be reposted — `{:error, :restricted}` otherwise. A new repost is
  distributed like a new post: `{:new_repost, %{repost_id:, post_id:,
  reposter_id:}}` goes to the reposter's and every follower's activity
  topic. While reposts exist the author cannot restrict the post's audience
  (see `update_post/2`), only delete it.
  """
  def repost_post(%User{} = user, %Post{} = post) do
    if restricted?(post) do
      {:error, :restricted}
    else
      case engage(PostRepost, :repost, user, post) do
        {:ok, %PostRepost{} = repost} -> broadcast_new_repost(repost)
        {:ok, :noop} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  @doc "Removes `user`'s repost (idempotent). The last one lifts the audience lock."
  def unrepost_post(%User{} = user, %Post{} = post),
    do: disengage(PostRepost, :repost, user, post)

  @doc "Whether any reposts of this post exist (the audience lock)."
  def has_reposts?(%Post{id: id}), do: has_reposts?(id)

  def has_reposts?(post_id) when is_binary(post_id) do
    Repo.exists?(from(r in PostRepost, where: r.post_id == ^post_id))
  end

  @doc "Whether any replies to this post exist (the audience lock, like reposts)."
  def has_replies?(%Post{id: id}), do: has_replies?(id)

  def has_replies?(post_id) when is_binary(post_id) do
    Repo.exists?(from(r in PostReply, where: r.parent_post_id == ^post_id))
  end

  # A repost or reply pins the audience open: someone else now carries or
  # answers the post, so narrowing it would silently break their share or
  # strand their reply's context. Deleting stays possible.
  defp check_visibility_lock(%Post{} = post, denials) do
    if denials != [] and (has_reposts?(post) or has_replies?(post)) do
      {:error, :visibility_locked}
    else
      :ok
    end
  end

  defp engage(schema, kind, %User{} = user, %Post{} = post) do
    if visible_to?(post, user) do
      now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

      row = %{
        id: UUIDv7.generate(),
        user_id: user.id,
        post_id: post.id,
        inserted_at: now,
        updated_at: now
      }

      # Ids are minted client-side, so a returned id no longer signals whether
      # the insert happened — insert_all's row count does (0 on conflict).
      case Repo.insert_all(schema, [row],
             on_conflict: :nothing,
             conflict_target: [:post_id, :user_id],
             returning: true
           ) do
        {0, _} ->
          {:ok, :noop}

        {1, [row]} ->
          broadcast_engagement(kind, user.id, post.id, true)
          {:ok, row}
      end
    else
      {:error, :not_visible}
    end
  end

  # Removing your own engagement needs no visibility check.
  defp disengage(schema, kind, %User{} = user, %Post{} = post) do
    {count, _} =
      Repo.delete_all(from(e in schema, where: e.post_id == ^post.id and e.user_id == ^user.id))

    if count > 0, do: broadcast_engagement(kind, user.id, post.id, false)
    :ok
  end

  # The four engagement counters (likes / bookmarks / reposts / replies),
  # counted live from the rows. Defined once here so both `engagement_counts/1`
  # and `post_engagement/2` select the exact same fragments; pass the post
  # binding so the correlated subqueries reference its id. Keep the map keys in
  # sync with the zero-count fallback in `engagement_counts/1`.
  defmacrop engagement_count_select(post) do
    quote do
      %{
        likes:
          fragment("(SELECT count(*) FROM post_likes l WHERE l.post_id = ?)", unquote(post).id),
        bookmarks:
          fragment(
            "(SELECT count(*) FROM post_bookmarks b WHERE b.post_id = ?)",
            unquote(post).id
          ),
        reposts:
          fragment("(SELECT count(*) FROM post_reposts r WHERE r.post_id = ?)", unquote(post).id),
        replies:
          fragment(
            "(SELECT count(*) FROM post_replies r WHERE r.parent_post_id = ?)",
            unquote(post).id
          )
      }
    end
  end

  @doc "Like / bookmark / repost / reply counts of a post, in one round trip."
  def engagement_counts(post_id) do
    query =
      from(p in Post, where: p.id == ^post_id)
      |> select([p], engagement_count_select(p))

    Repo.one(query) || %{likes: 0, bookmarks: 0, reposts: 0, replies: 0}
  end

  @doc "How many replies a post has (raw row count, like the other counters)."
  def reply_count(post_id) do
    Repo.aggregate(from(r in PostReply, where: r.parent_post_id == ^post_id), :count)
  end

  @doc """
  Everything the action bar needs in one round trip: the three counts,
  the viewer's own flags (`liked?` / `bookmarked?` / `reposted?`), whether
  the post is restricted (restricted posts cannot be reposted) and the
  author id. The viewer is a `%User{}`, a user id, or `nil` (anonymous).
  `nil` when the post is gone.
  """
  def post_engagement(post_id, viewer) do
    viewer_id =
      case viewer do
        %User{id: id} -> id
        id when is_binary(id) -> id
        # The nil UUID can never match a row: "anonymous" without a NULL arm.
        nil -> "00000000-0000-0000-0000-000000000000"
      end

    query =
      from(p in Post, where: p.id == ^post_id)
      |> select([p], engagement_count_select(p))
      |> select_merge([p], %{
        liked?:
          fragment(
            "EXISTS (SELECT 1 FROM post_likes l WHERE l.post_id = ? AND l.user_id = ?)",
            p.id,
            type(^viewer_id, UUIDv7)
          ),
        bookmarked?:
          fragment(
            "EXISTS (SELECT 1 FROM post_bookmarks b WHERE b.post_id = ? AND b.user_id = ?)",
            p.id,
            type(^viewer_id, UUIDv7)
          ),
        reposted?:
          fragment(
            "EXISTS (SELECT 1 FROM post_reposts r WHERE r.post_id = ? AND r.user_id = ?)",
            p.id,
            type(^viewer_id, UUIDv7)
          ),
        restricted?: fragment("EXISTS (SELECT 1 FROM post_denials d WHERE d.post_id = ?)", p.id),
        author_id: p.user_id
      })

    Repo.one(query)
  end

  @doc "Subscribes the caller to a post's `{:post_counters, …}` updates."
  def subscribe_post(post_id) do
    Phoenix.PubSub.subscribe(Vutuv.PubSub, post_topic(post_id))
  end

  defp post_topic(post_id), do: "post:#{post_id}"

  defp broadcast_engagement(kind, user_id, post_id, active?) do
    payload = Map.put(engagement_counts(post_id), :post_id, post_id)
    Phoenix.PubSub.broadcast(Vutuv.PubSub, post_topic(post_id), {:post_counters, payload})

    Vutuv.Activity.broadcast(
      user_id,
      {:engagement_changed, %{kind: kind, post_id: post_id, active?: active?}}
    )
  end

  ## Reading

  @doc """
  One page of `viewer`'s newsfeed: own posts plus posts **and reposts** of
  followed (activated) authors, visibility-filtered, newest first.

  Entries are maps `%{id:, post:, reposted_by:, at:}` — `id` is
  `"post-<id>"` / `"repost-<id>"` (unique per entry, the stream DOM id),
  `reposted_by` the carrying user (or `nil` for original posts), `at` the
  feed timestamp (publication or repost time). Posts are preloaded for
  rendering.

  Returns `%{entries:, more?:, next_cursor:}` — pass `cursor:` back for the
  next older page. The cursor (and the merge across the two sources) is the
  shared `Vutuv.FeedPage` scheme. Treat it as opaque.
  """
  def feed_page(%User{} = viewer, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_feed_limit)
    cursor = Keyword.get(opts, :cursor)

    page =
      Vutuv.FeedPage.paginate(
        [&feed_post_items(viewer, &1, &2), &feed_repost_items(viewer, &1, &2)],
        limit,
        cursor
      )

    %{page | entries: hydrate_posts(page.entries)}
  end

  defp feed_post_items(%User{id: viewer_id} = viewer, fetch_n, cursor) do
    from(p in Post,
      join: u in assoc(p, :user),
      where: p.user_id == ^viewer_id or p.user_id in subquery(followees_of(viewer_id)),
      where: p.user_id == ^viewer_id or is_nil(u.activated?) or u.activated? == true,
      order_by: [desc: p.inserted_at, desc: p.id],
      limit: ^fetch_n
    )
    |> scope_visible(viewer)
    |> posts_at_or_before(cursor)
    |> Repo.all()
    |> Enum.map(&%{id: "post-#{&1.id}", post: &1, reposted_by: nil, at: &1.inserted_at})
  end

  # Reposts distribute through the reposter: their followers see the post,
  # stamped with the repost time. Both the reposter and the original author
  # must be activated (a repost must not amplify a hidden author), and the
  # post itself passes the viewer's visibility scope as usual.
  defp feed_repost_items(%User{id: viewer_id} = viewer, fetch_n, cursor) do
    from(p in Post,
      join: r in PostRepost,
      as: :repost,
      on: r.post_id == p.id,
      join: reposter in User,
      on: reposter.id == r.user_id,
      join: u in assoc(p, :user),
      where: r.user_id == ^viewer_id or r.user_id in subquery(followees_of(viewer_id)),
      where:
        r.user_id == ^viewer_id or is_nil(reposter.activated?) or reposter.activated? == true,
      where: p.user_id == ^viewer_id or is_nil(u.activated?) or u.activated? == true,
      order_by: [desc: r.inserted_at, desc: r.id],
      limit: ^fetch_n,
      select: {r.id, r.inserted_at, p, reposter}
    )
    |> scope_visible(viewer)
    |> reposts_at_or_before(cursor)
    |> Repo.all()
    |> Enum.map(fn {id, at, post, reposter} ->
      %{id: "repost-#{id}", post: post, reposted_by: reposter, at: at}
    end)
  end

  defp followees_of(viewer_id) do
    from(c in Follow, where: c.follower_id == ^viewer_id, select: c.followee_id)
  end

  defp posts_at_or_before(query, nil), do: query
  defp posts_at_or_before(query, %{at: at}), do: where(query, [p], p.inserted_at <= ^at)

  defp reposts_at_or_before(query, nil), do: query

  defp reposts_at_or_before(query, %{at: at}),
    do: where(query, [repost: r], r.inserted_at <= ^at)

  # Batch-preloads the posts inside a list of timeline entries.
  defp hydrate_posts(entries) do
    posts = entries |> Enum.map(& &1.post) |> Repo.preload(post_preloads())
    Enum.zip_with(entries, posts, &%{&1 | post: &2})
  end

  @doc """
  The newest timeline entries of `author` that `viewer` may see (profile
  page section): own posts plus reposts, same entry shape as `feed_page/2`
  (`reposted_by` is the author for repost entries).
  """
  def profile_posts(%User{} = author, viewer, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_profile_limit)

    author
    |> author_timeline_query(viewer)
    |> order_by([t], desc: t.at, desc: t.ref_id)
    |> limit(^limit)
    |> Repo.all()
    |> author_entries(author)
  end

  @doc "How many timeline entries of `author` `viewer` may see (the \"View all\" label)."
  def count_author_posts(%User{} = author, viewer) do
    author |> author_timeline_query(viewer) |> Repo.aggregate(:count)
  end

  @doc """
  One offset page of `author`'s timeline visible to `viewer` — the author
  archive at `/:slug/posts` (browse-style pagination, like followers/tags).
  An optional `period` (`{from, to}` dates, inclusive) scopes it to the
  year/month/day index pages; reposts date by the repost, not the original
  publication. Returns `{entries, total}` (entry shape as in `feed_page/2`).
  """
  def author_posts_page(%User{} = author, viewer, params, period \\ nil) do
    query = author |> author_timeline_query(viewer) |> scope_period(period)
    total = Repo.aggregate(query, :count)

    entries =
      query
      |> order_by([t], desc: t.at, desc: t.ref_id)
      |> Vutuv.Pages.paginate(params, total)
      |> Repo.all()
      |> author_entries(author)

    {entries, total}
  end

  defp scope_period(query, nil), do: query

  defp scope_period(query, {%Date{} = from, %Date{} = to}) do
    where(query, [t], t.on_date >= ^from and t.on_date <= ^to)
  end

  # The author's timeline rows — own posts (dated by publication) and own
  # reposts (dated by the repost) — as one subquery the callers count,
  # period-scope and page like a plain table.
  defp author_timeline_query(%User{id: author_id}, viewer) do
    originals =
      from(p in Post,
        where: p.user_id == ^author_id,
        select: %{
          kind: type(^"post", :string),
          ref_id: p.id,
          post_id: p.id,
          at: p.inserted_at,
          on_date: p.published_on
        }
      )
      |> scope_visible(viewer)

    reposts =
      from(p in Post,
        join: r in PostRepost,
        on: r.post_id == p.id,
        where: r.user_id == ^author_id,
        select: %{
          kind: type(^"repost", :string),
          ref_id: r.id,
          post_id: p.id,
          at: r.inserted_at,
          on_date: fragment("(?)::date", r.inserted_at)
        }
      )
      |> scope_visible(viewer)

    from(t in subquery(union_all(originals, ^reposts)))
  end

  defp author_entries(rows, %User{} = author) do
    posts =
      from(p in Post, where: p.id in ^Enum.uniq(Enum.map(rows, & &1.post_id)))
      |> Repo.all()
      |> Repo.preload(post_preloads())
      |> Map.new(&{&1.id, &1})

    for row <- rows, post = posts[row.post_id] do
      %{
        id: "#{row.kind}-#{row.ref_id}",
        post: post,
        reposted_by: if(row.kind == "repost", do: author),
        at: row.at
      }
    end
  end

  @doc """
  The direct replies to `post` that `viewer` may see, oldest first — the
  thread under the permalink page. Plain preloaded posts, capped at
  `:limit` (default #{@default_thread_limit}).
  """
  def list_replies(%Post{id: parent_id}, viewer, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_thread_limit)

    from(p in Post,
      join: r in PostReply,
      on: r.post_id == p.id,
      where: r.parent_post_id == ^parent_id,
      order_by: [asc: p.inserted_at, asc: p.id],
      limit: ^limit
    )
    |> scope_visible(viewer)
    |> Repo.all()
    |> Repo.preload(post_preloads())
  end

  @doc """
  One page of the posts `user` liked, newest like first, visibility-filtered
  at read time (a since-restricted post drops out). Cursor-paginated like
  the feed; entries are plain preloaded posts.
  """
  def liked_posts_page(%User{} = user, opts \\ []), do: engaged_posts_page(PostLike, user, opts)

  @doc "One page of the posts `user` bookmarked — see `liked_posts_page/2`."
  def bookmarked_posts_page(%User{} = user, opts \\ []),
    do: engaged_posts_page(PostBookmark, user, opts)

  defp engaged_posts_page(schema, %User{id: user_id} = user, opts) do
    limit = Keyword.get(opts, :limit, @default_feed_limit)
    cursor = Keyword.get(opts, :cursor)

    rows =
      from(p in Post,
        join: e in ^schema,
        as: :engagement,
        on: e.post_id == p.id,
        where: e.user_id == ^user_id,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: ^(limit + 1),
        select: {p, e.inserted_at, e.id}
      )
      |> scope_visible(user)
      |> engaged_before(cursor)
      |> Repo.all()

    taken = Enum.take(rows, limit)
    posts = taken |> Enum.map(&elem(&1, 0)) |> Repo.preload(post_preloads())
    more? = length(rows) > limit

    next_cursor =
      if more? do
        {_post, at, id} = List.last(taken)
        %{at: at, id: id}
      end

    %{entries: posts, more?: more?, next_cursor: next_cursor}
  end

  defp engaged_before(query, nil), do: query

  defp engaged_before(query, %{at: at, id: id}) do
    where(
      query,
      [engagement: e],
      e.inserted_at < ^at or (e.inserted_at == ^at and e.id < ^id)
    )
  end

  @doc "The permalink lookup: `author`'s preloaded post by id, or `nil`."
  def get_post(%User{id: author_id}, id) do
    case UUIDv7.cast_or_nil(id) do
      nil ->
        nil

      id ->
        from(p in Post, where: p.user_id == ^author_id and p.id == ^id)
        |> Repo.one()
        |> preload_post()
    end
  end

  @doc "A preloaded post by id, or `nil` (live-feed pill, edit page)."
  def get_post(id) do
    # cast_or_nil: a garbage id in /posts/:id/edit is a nil (404), not a 500.
    case Vutuv.UUIDv7.cast_or_nil(id) do
      nil -> nil
      id -> Post |> Repo.get(id) |> preload_post()
    end
  end

  defp preload_post(nil), do: nil
  defp preload_post(%Post{} = post), do: Repo.preload(post, post_preloads(), force: true)

  defp post_preloads do
    # denials with group/denied_user: the author-facing audience display
    # names them (never shown to other viewers). reply_ref goes exactly one
    # level deep (the banner names the direct parent only) — preloading the
    # parent's own reply_ref would recurse.
    [
      :user,
      :images,
      denials: [:group, :denied_user],
      tags: from(t in Tag, order_by: t.name),
      reply_ref: [:parent_author, parent_post: :user]
    ]
  end

  @doc """
  The root-relative permalink path, e.g.
  `/stefan/posts/019748c8-1a2b-7c3d-8e4f-5a6b7c8d9e0f`. Lives under the
  author archive (`/:slug/posts`), whose year/month/day pages stay
  date-scoped index views. Requires `:user` to be preloaded.
  """
  def path(%Post{user: %User{} = user, id: id}) do
    "/#{user.active_slug}/posts/#{id}"
  end

  ## Images

  @doc """
  Stores an eagerly-uploaded image (WebP versions + private original) and
  creates its pending row. Returns `{:ok, image}`, `{:error, :too_large}` or
  `{:error, :invalid_file}`.
  """
  def create_pending_image(%User{} = user, %Plug.Upload{} = upload) do
    create_pending_image(user, upload.path, upload.filename)
  end

  def create_pending_image(%User{} = user, path, filename) do
    if File.stat!(path).size > max_image_filesize() do
      {:error, :too_large}
    else
      token = PostImage.gen_token()

      case PostImageStore.store(path, filename, token) do
        {:ok, meta} ->
          %PostImage{user_id: user.id, token: token}
          |> Ecto.Changeset.change(meta)
          |> Repo.insert()

        {:error, _} = error ->
          error
      end
    end
  end

  def update_image_alt(%PostImage{} = image, alt) do
    image |> PostImage.alt_changeset(%{alt: alt}) |> Repo.update()
  end

  @doc "Deletes a pending (unattached) image: row and files."
  def delete_pending_image(%PostImage{post_id: nil} = image) do
    {count, _} =
      Repo.delete_all(from(i in PostImage, where: i.id == ^image.id and is_nil(i.post_id)))

    if count == 1, do: PostImageStore.delete(image.token)
    :ok
  end

  @doc "The image behind a proxy token, with its post preloaded; `nil` when unknown."
  def get_image_by_token(token) when is_binary(token) do
    PostImage
    |> Repo.get_by(token: token)
    |> case do
      nil -> nil
      image -> Repo.preload(image, :post)
    end
  end

  def get_image_by_token(_), do: nil

  @doc """
  Whether `viewer` may fetch this image's bytes: pending images belong to
  their uploader alone; attached images follow the post's audience.
  """
  def image_visible_to?(%PostImage{post_id: nil, user_id: uploader_id}, viewer) do
    match?(%User{id: ^uploader_id}, viewer)
  end

  def image_visible_to?(%PostImage{} = image, viewer) do
    post =
      case image.post do
        %Post{} = post -> post
        # Not preloaded (NotLoaded is truthy — don't `||` this).
        _ -> Repo.get(Post, image.post_id)
      end

    visible_to?(post, viewer)
  end

  @doc """
  Removes pending images older than a day (abandoned composer sessions),
  files included. Returns the number of swept images.
  """
  def sweep_pending_images(max_age_hours \\ @pending_max_age_hours) do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -max_age_hours * 3600)

    from(i in PostImage, where: is_nil(i.post_id) and i.inserted_at < ^cutoff)
    |> Repo.all()
    |> Enum.count(fn image ->
      # Re-check pending state in the delete itself: the image may have been
      # attached between the read and now.
      {count, _} =
        Repo.delete_all(from(i in PostImage, where: i.id == ^image.id and is_nil(i.post_id)))

      if count == 1, do: PostImageStore.delete(image.token)
      count == 1
    end)
  end

  @doc """
  Person typeahead for the composer's "Hide from…" sheet: activated members
  matching `term` by name or slug, the author excluded (denying yourself is
  a no-op by invariant). Returns `[]` below two characters.
  """
  def search_users(%User{id: author_id}, term, limit \\ 8) when is_binary(term) do
    term = String.trim(term)

    if String.length(term) < 2 do
      []
    else
      pattern = "%" <> escape_like(term) <> "%"

      Repo.all(
        from(u in User,
          where: u.id != ^author_id,
          where: is_nil(u.activated?) or u.activated? == true,
          where:
            ilike(u.first_name, ^pattern) or ilike(u.last_name, ^pattern) or
              ilike(u.active_slug, ^pattern) or
              ilike(fragment("? || ' ' || ?", u.first_name, u.last_name), ^pattern),
          order_by: [u.first_name, u.last_name],
          limit: ^limit
        )
      )
    end
  end

  defp escape_like(term), do: String.replace(term, ~r/([\\%_])/, "\\\\\\1")

  ## Tags

  defp parse_tag_values(nil), do: []

  defp parse_tag_values(values) when is_binary(values),
    do: parse_tag_values(String.split(values, ","))

  defp parse_tag_values(values) when is_list(values) do
    values
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.take(@max_tags)
  end

  # Find-or-create by name/slug (case-insensitive), racing gracefully.
  # Unresolvable values (e.g. names whose slug exceeds the limit) are skipped:
  # a post must not fail because one tag was odd.
  defp tag_ids_for(values) do
    values
    |> Enum.map(&tag_for_value/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp tag_for_value(value) do
    case lookup_tag(value) do
      %Tag{id: id} -> id
      nil -> insert_tag_for_value(value)
    end
  end

  defp insert_tag_for_value(value) do
    case Repo.insert(Tag.changeset(%Tag{}, %{"value" => value})) do
      {:ok, tag} -> tag.id
      # Lost a race or invalid value — one more lookup, then give up.
      {:error, _} -> with(%Tag{id: id} <- lookup_tag(value), do: id)
    end
  end

  defp lookup_tag(value) do
    down = String.downcase(value)

    Repo.one(
      from(t in Tag,
        where: fragment("lower(?)", t.name) == ^down or t.slug == ^down,
        limit: 1
      )
    )
  end

  ## Broadcasts

  defp broadcast_new_post(%Post{} = post) do
    event = {:new_post, %{post_id: post.id, author_id: post.user_id}}
    broadcast_to_followers(post.user_id, event)
  end

  # A fresh repost distributes like a fresh post — to the reposter's own
  # sessions and their followers' feeds.
  defp broadcast_new_repost(%PostRepost{} = repost) do
    event =
      {:new_repost, %{repost_id: repost.id, post_id: repost.post_id, reposter_id: repost.user_id}}

    broadcast_to_followers(repost.user_id, event)
  end

  # A new reply ticks the parent's open action bars and notifies its author
  # (self-replies are not news).
  defp broadcast_reply(%Post{} = parent, %Post{} = reply) do
    broadcast_reply_count(parent.id)

    if parent.user_id != reply.user_id do
      Vutuv.Activity.notify_reply(parent.user_id, reply.user)
    end
  end

  @doc """
  The counterpart to `broadcast_new_post/1`: tells open clients a post is gone.
  `{:post_deleted, …}` goes to the post's topic (so its action bars empty,
  including those on repost cards) and to the recipients' feed topics (so the
  feed drops the entry). Pass the author id — its followers are looked up — or,
  when the author is already deleted (account teardown), an explicit list of
  recipient ids captured beforehand.
  """
  def broadcast_post_deleted(post_id, author_id) when is_binary(author_id) do
    broadcast_post_deleted(post_id, [author_id | follower_ids(author_id)])
  end

  def broadcast_post_deleted(post_id, recipient_ids) when is_list(recipient_ids) do
    event = {:post_deleted, %{post_id: post_id}}
    Phoenix.PubSub.broadcast(Vutuv.PubSub, post_topic(post_id), event)
    Enum.each(recipient_ids, &Vutuv.Activity.broadcast(&1, event))
  end

  @doc """
  Re-broadcasts a parent post's fresh absolute counters on its topic — used
  after a reply is created or deleted so the parent's reply counter ticks on
  every open action bar.
  """
  def broadcast_reply_count(parent_id) do
    payload = Map.put(engagement_counts(parent_id), :post_id, parent_id)
    Phoenix.PubSub.broadcast(Vutuv.PubSub, post_topic(parent_id), {:post_counters, payload})
  end

  @doc """
  Snapshot — taken *before* an account is deleted — of what its post teardown
  must broadcast afterwards, when the follow edges and posts are already gone:
  the account's `post_ids`, the `follower_ids` whose feeds may show them, and
  the `reply_parent_ids` of surviving parents whose reply counters must tick
  down. Pair with `broadcast_post_deleted/2` + `broadcast_reply_count/1`.
  """
  def deletion_targets_for_user(user_id) do
    post_ids = Repo.all(from(p in Post, where: p.user_id == ^user_id, select: p.id))

    reply_parent_ids =
      Repo.all(
        from(r in PostReply,
          join: reply in Post,
          on: reply.id == r.post_id,
          join: parent in Post,
          on: parent.id == r.parent_post_id,
          where: reply.user_id == ^user_id and parent.user_id != ^user_id,
          distinct: true,
          select: r.parent_post_id
        )
      )

    %{post_ids: post_ids, follower_ids: follower_ids(user_id), reply_parent_ids: reply_parent_ids}
  end

  defp broadcast_to_followers(user_id, event) do
    Enum.each([user_id | follower_ids(user_id)], &Vutuv.Activity.broadcast(&1, event))
  end

  defp follower_ids(user_id) do
    Repo.all(from(c in Follow, where: c.followee_id == ^user_id, select: c.follower_id))
  end

  defp reply_parent_id(post_id) do
    Repo.one(from(r in PostReply, where: r.post_id == ^post_id, select: r.parent_post_id))
  end

  ## Param helpers (attrs arrive with atom keys from code, string keys from forms)

  defp fetch(attrs, key) when is_map(attrs) and is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp parse_ids(ids) when is_list(ids),
    do: ids |> Enum.map(&parse_id/1) |> Enum.reject(&is_nil/1)

  # Ids are UUID strings; anything that does not cast (stale form payloads,
  # tampering) is dropped rather than raising in the changeset cast.
  defp parse_id(id), do: Vutuv.UUIDv7.cast_or_nil(id)
end
