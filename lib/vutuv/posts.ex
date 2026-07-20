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
  coordinate. `published_on` (the Berlin calendar day at insert time, never
  changed by edits) scopes the day/month/year archive index pages under the
  same `/:slug/posts` prefix.

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
  import Vutuv.Moderation.Query, only: [account_hidden: 1, account_confirmed_row: 1]
  import Vutuv.SearchText, only: [escape_like: 1, normalize_search: 1, name_ilike: 3]

  alias Vutuv.Accounts.User
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Pages
  alias Vutuv.PostImageStore
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostBookmark
  alias Vutuv.Posts.PostDenial
  alias Vutuv.Posts.PostImage
  alias Vutuv.Posts.PostLike
  alias Vutuv.Posts.PostReply
  alias Vutuv.Posts.PostRepost
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Posts.PostTag
  alias Vutuv.Posts.Screenshots
  alias Vutuv.Posts.ScreenshotWorker
  alias Vutuv.Repo
  alias Vutuv.Social.Follow
  alias Vutuv.Tags
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
    * `:denials` — list of `%{"denied_user_id" => id}` / `%{"wildcard" => w}`
      maps (see `Vutuv.Posts.PostDenial`)
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
          # Follow-only federation: a federating author's public post goes
          # out to their remote followers (no-op for everyone else).
          Vutuv.Fediverse.federate_new_post(post)
          # A single-URL, image-less post gets a link screenshot, captured off
          # the request path via the durable queue.
          reconcile_screenshot(post)
          {:ok, post}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Creates a reply to `parent` for `author` — a normal post (same attrs,
  validations and broadcasts as `create_post/2`, **except** it carries no
  denials of its own: a reply inherits the parent's audience, issue #774) plus
  a `Vutuv.Posts.PostReply` row naming the parent. Only **public** parents
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
         :ok <- check_image_count(image_ids),
         # A reply has no audience of its own: it inherits the parent's, which
         # check_reply_allowed already constrains to public. Any denials in the
         # params are dropped, so the public reply count and the parent-author
         # notification only ever concern content the author can see (issue #774).
         {:ok, changeset} <- build_changeset(%Post{user_id: author.id}, attrs, [], image_ids) do
      case insert_post(changeset, image_ids, parent) do
        {:ok, post} ->
          post = preload_post(post)
          broadcast_new_post(post)
          broadcast_reply(parent, post)
          Vutuv.Fediverse.federate_new_post(post)
          reconcile_screenshot(post)
          {:ok, post}

        {:error, _} = error ->
          error
      end
    end
  end

  defp check_reply_allowed(%User{} = author, %Post{} = parent) do
    cond do
      not visible_to?(parent, author) -> {:error, :not_visible}
      # Query restriction fresh from the DB, not the (possibly stale) preloaded
      # denials: the reply LiveView holds the parent struct from mount, and the
      # author may have restricted the post after it was loaded.
      parent_restricted_now?(parent) -> {:error, :restricted}
      # A block between author and parent author refuses the reply with the
      # same opaque :restricted the disabled reply button already explains.
      blocked?(author, parent) -> {:error, :restricted}
      true -> :ok
    end
  end

  # A bare %Post{id: id} carries denials: %NotLoaded{}, so it falls through to
  # restricted?/1's forced-fresh query clause rather than reading a (possibly
  # stale) preloaded association.
  defp parent_restricted_now?(%Post{id: id}), do: restricted?(%Post{id: id})

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
        # A reported post that its owner edits leaves the moderation freezer
        # (the owner's self-service round; see Vutuv.Moderation).
        Vutuv.Moderation.content_edited(updated)
        updated = preload_post(updated)
        # Remote copies follow the edit (Update) — or, if the audience just
        # closed, leave public view (Delete, best effort).
        Vutuv.Fediverse.federate_post_update(updated)
        # An edit can add/remove the qualifying URL or an image: enqueue, refresh
        # or drop the link screenshot to match.
        reconcile_screenshot(updated)
        {:ok, updated}

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
    post = Repo.preload(post, [:images, :screenshot])
    parent_id = reply_parent_id(post.id)

    case Repo.delete(post) do
      {:ok, deleted} ->
        Enum.each(post.images, &PostImageStore.delete(&1.token))
        # The post_screenshots row cascades with the post; its stored files do
        # not, so purge them explicitly (a no-op when there was no screenshot).
        if post.screenshot, do: Screenshots.delete(post.screenshot)
        broadcast_post_deleted(post.id, post.user_id)
        if parent_id, do: broadcast_reply_count(parent_id)
        # Deleting reported content settles its moderation case.
        Vutuv.Moderation.content_deleted(deleted)
        # Remote copies get a Delete(Tombstone) — best effort by protocol.
        Vutuv.Fediverse.federate_post_delete(deleted)
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

  # Stamps the Berlin-day publication date (the archive coordinate; the same
  # calendar day the rendered timestamps use) and commits the post, its image
  # claims and — for a reply — the PostReply row in one transaction, so post
  # and reference land (or roll back) together.
  defp insert_post(changeset, image_ids, parent \\ nil) do
    Repo.transaction(fn ->
      changeset
      |> Ecto.Changeset.change(published_on: Vutuv.BerlinTime.today())
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
  # structs. You cannot deny yourself; a denied user must exist; wildcards must
  # be known. Duplicates collapse. Every denied-user id is checked in one query
  # (existing_denied_user_ids/1), never one Repo.exists? per denial.
  defp normalize_denials(author_id, denials) when is_list(denials) do
    targets = Enum.map(denials, &parse_denial_target/1)
    known_ids = existing_denied_user_ids(targets)

    targets
    |> Enum.reduce_while({:ok, []}, fn target, {:ok, acc} ->
      case validate_denial_target(author_id, target, known_ids) do
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

  # Parses a denial map into its single target — `{:denied_user_id, id}` or
  # `{:wildcard, w}` — or `:error` when it does not carry exactly one target
  # (mirrors the DB check constraint).
  defp parse_denial_target(denial) when is_map(denial) do
    targets = [
      denied_user_id: denial |> fetch(:denied_user_id) |> parse_id(),
      wildcard: fetch(denial, :wildcard)
    ]

    case Enum.reject(targets, fn {_key, value} -> is_nil(value) end) do
      [target] -> target
      _ -> :error
    end
  end

  defp parse_denial_target(_other), do: :error

  # The denials' denied-user ids that actually exist, as a MapSet, in one query
  # (no per-denial Repo.exists?). Empty when no denial names a user.
  defp existing_denied_user_ids(targets) do
    ids = for {:denied_user_id, id} <- targets, do: id

    if ids == [] do
      MapSet.new()
    else
      from(u in User, where: u.id in ^ids, select: u.id) |> Repo.all() |> MapSet.new()
    end
  end

  defp validate_denial_target(_author_id, :error, _known_ids), do: :error

  defp validate_denial_target(author_id, {:denied_user_id, denied_user_id}, known_ids) do
    if denied_user_id != author_id and MapSet.member?(known_ids, denied_user_id),
      do: {:ok, %{denied_user_id: denied_user_id}},
      else: :error
  end

  defp validate_denial_target(_author_id, {:wildcard, wildcard}, _known_ids) do
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
    not moderation_hidden?(post) and not restricted?(post)
  end

  def visible_to?(%Post{} = post, %User{id: viewer_id} = viewer) do
    if moderation_hidden?(post) do
      # Admins can open a frozen permalink to review it in place.
      viewer.admin? == true
    else
      not Repo.exists?(denial_match_query(post.id, post.user_id, viewer_id))
    end
  end

  @doc """
  A post is in the moderation freezer, or its author's whole account is
  hidden (frozen pending review, suspended, or deactivated). Such posts
  vanish for everyone but the author (first `visible_to?/2` clause) and
  admins — and unlike a plain audience restriction, no teaser stands in for
  them (a frozen post gets a 404, not a "Follow to read" tombstone).
  The policy itself lives in Vutuv.Moderation; render paths usually carry
  the author preloaded, so the user fetch is the fallback, not the rule.
  """
  def moderation_hidden?(%Post{} = post) do
    post.frozen_at != nil or author_hidden?(post)
  end

  defp author_hidden?(%Post{user: %User{} = author}),
    do: Vutuv.Moderation.account_hidden?(author)

  defp author_hidden?(%Post{user_id: author_id}) do
    case Repo.get(User, author_id) do
      nil -> false
      author -> Vutuv.Moderation.account_hidden?(author)
    end
  end

  # All denial rows of the post that match this viewer (union semantics).
  # The or-chain mirrors one SQL expression branch-for-branch; splitting it
  # into helpers would only obscure the query, so the complexity is accepted.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
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
               "NOT (EXISTS (SELECT 1 FROM follows f WHERE f.follower_id = ? AND f.followee_id = ?) AND EXISTS (SELECT 1 FROM follows f WHERE f.follower_id = ? AND f.followee_id = ?))",
               type(^viewer_id, UUIDv7),
               type(^author_id, UUIDv7),
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
    |> scope_unfrozen(nil)
  end

  def scope_visible(query, %User{id: viewer_id} = viewer) do
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
                  OR (d.wildcard = 'non_connections' AND NOT (
                        EXISTS (SELECT 1 FROM follows f
                          WHERE f.follower_id = ? AND f.followee_id = ?)
                        AND EXISTS (SELECT 1 FROM follows f
                          WHERE f.follower_id = ? AND f.followee_id = ?)))
                )
            )
            """,
            p.id,
            type(^viewer_id, UUIDv7),
            type(^viewer_id, UUIDv7),
            p.user_id,
            p.user_id,
            type(^viewer_id, UUIDv7),
            type(^viewer_id, UUIDv7),
            p.user_id,
            p.user_id,
            type(^viewer_id, UUIDv7)
          )
    )
    |> scope_unfrozen(viewer)
  end

  # The moderation arm of scope_visible/2: frozen posts and posts whose
  # author's account is hidden (frozen / suspended / deactivated) vanish from
  # every list, except the author's own. The SQL twin of moderation_hidden?/1;
  # the hidden-account condition itself is owned by Vutuv.Moderation.Query.
  defp scope_unfrozen(query, viewer) do
    passes = dynamic([p], is_nil(p.frozen_at) and not account_hidden(p.user_id))

    filter =
      case viewer do
        %User{id: viewer_id} -> dynamic([p], p.user_id == ^viewer_id or ^passes)
        nil -> passes
      end

    where(query, ^filter)
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

  @doc """
  Likes `post` as `user` (idempotent). Only visible posts can be liked, and
  never across a block (a like notifies the author — a harassment vector).
  """
  def like_post(%User{} = user, %Post{} = post) do
    if blocked?(user, post) do
      {:error, :blocked}
    else
      do_like_post(user, post)
    end
  end

  defp do_like_post(%User{} = user, %Post{} = post) do
    case engage(PostLike, :like, user, post) do
      {:ok, %PostLike{}} ->
        # A fresh like is news for the author; the idempotent repeat is not,
        # and neither is liking your own post.
        if post.user_id != user.id do
          Vutuv.Activity.notify_like(post.user_id, user, post.id)
        end

        :ok

      {:ok, :noop} ->
        :ok

      {:error, _} = error ->
        error
    end
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
    cond do
      restricted?(post) ->
        {:error, :restricted}

      # No reposting across a block: it pins the author's audience open and
      # redistributes their words - both unacceptable from/to a blocked party.
      blocked?(user, post) ->
        {:error, :blocked}

      true ->
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
      case Vutuv.Engagement.insert_if_new(
             schema,
             %{user_id: user.id, post_id: post.id},
             [:post_id, :user_id]
           ) do
        :exists ->
          {:ok, :noop}

        {:inserted, row} ->
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
        # Only publicly-visible replies, matching the anonymous list_replies /
        # scope_visible view: the reply post must still exist, be unfrozen and
        # carry no denials. A reply can no longer be restricted apart from its
        # parent (issue #774), but a moderation-frozen or pre-#774 denied reply
        # must not inflate the public count.
        replies:
          fragment(
            """
            (SELECT count(*) FROM post_replies r
               JOIN posts rp ON rp.id = r.post_id
              WHERE r.parent_post_id = ?
                AND rp.frozen_at IS NULL
                AND NOT EXISTS (SELECT 1 FROM post_denials d WHERE d.post_id = rp.id)
                AND NOT EXISTS (SELECT 1 FROM users mu WHERE mu.id = rp.user_id
                                  AND (mu.frozen_at IS NOT NULL
                                    OR mu.deactivated_at IS NOT NULL
                                    OR mu.unreachable_at IS NOT NULL
                                    OR mu.suspended_until > (NOW() AT TIME ZONE 'utc'))))
            """,
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

  @doc """
  How many publicly-visible replies a post has: the reply post must still
  exist, be unfrozen and carry no denials, matching the anonymous
  `list_replies/3` thread (issue #774). The action bar's `engagement_counts/1`
  applies the same filter.
  """
  def reply_count(post_id) do
    Repo.one(
      from(r in PostReply,
        join: rp in Post,
        on: rp.id == r.post_id,
        where: r.parent_post_id == ^post_id and is_nil(rp.frozen_at),
        where: fragment("NOT EXISTS (SELECT 1 FROM post_denials d WHERE d.post_id = ?)", rp.id),
        # A reply whose author's account is hidden is excluded by list_replies /
        # scope_visible, so it must not inflate the public count either.
        where: not account_hidden(rp.user_id),
        select: count(r.id)
      )
    )
  end

  @doc """
  Everything the action bar needs in one round trip: the three counts,
  the viewer's own flags (`liked?` / `bookmarked?` / `reposted?`), whether
  the post is restricted (restricted posts cannot be reposted) and the
  author id. The viewer is a `%User{}`, a user id, or `nil` (anonymous).
  `nil` when the post is gone.
  """
  def post_engagement(post_id, viewer) do
    from(p in Post, where: p.id == ^post_id)
    |> engagement_select(engagement_viewer_id(viewer))
    |> Repo.one()
  end

  @doc """
  Batched `post_engagement/2`: the same per-post engagement (counts, the
  viewer's flags, `restricted?`, `author_id`) for many posts in one round trip,
  returned as `%{post_id => engagement}`. The feed pre-loads this for its page
  and hands each card's engagement to its action bar, so the per-card `Actions`
  LiveViews don't each run their own query on mount. `post_id` rides in the
  value too; otherwise the shape matches `post_engagement/2`.
  """
  def post_engagement_map(post_ids, viewer) do
    from(p in Post, where: p.id in ^post_ids)
    |> engagement_select(engagement_viewer_id(viewer))
    |> Repo.all()
    |> Map.new(fn engagement -> {engagement.id, engagement} end)
  end

  defp engagement_viewer_id(%User{id: id}), do: id
  defp engagement_viewer_id(id) when is_binary(id), do: id
  # The nil UUID can never match a row: "anonymous" without a NULL arm.
  defp engagement_viewer_id(nil), do: "00000000-0000-0000-0000-000000000000"

  # The shared SELECT behind post_engagement/2 and post_engagement_map/2, so the
  # single-post and batched paths can never drift in what the action bar reads.
  defp engagement_select(query, viewer_id) do
    query
    |> select([p], engagement_count_select(p))
    |> select_merge([p], %{
      id: p.id,
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
  end

  @doc "Subscribes the caller to a post's `{:post_counters, …}` updates."
  def subscribe_post(post_id) do
    Phoenix.PubSub.subscribe(Vutuv.PubSub, post_topic(post_id))
  end

  defp post_topic(post_id), do: "post:#{post_id}"

  defp broadcast_counters(post_id, extra \\ %{}) do
    payload = engagement_counts(post_id) |> Map.put(:post_id, post_id) |> Map.merge(extra)
    Phoenix.PubSub.broadcast(Vutuv.PubSub, post_topic(post_id), {:post_counters, payload})
  end

  defp broadcast_engagement(kind, user_id, post_id, active?) do
    # Absolute counts for every open action bar on this post (idempotent). The
    # `by_user_id` tag lets the actor's own bars — in their other tabs — re-sync
    # their like/bookmark/repost *flags* off this same message, so an action bar
    # no longer has to subscribe to the actor's whole activity firehose just to
    # hear about its own toggles (see VutuvWeb.PostLive.Actions).
    broadcast_counters(post_id, %{by_user_id: user_id})

    # The Saved (likes/bookmarks) page still reacts on the actor's activity
    # topic: it may need to add or drop a card for a post it is not subscribed
    # to, which the per-post topic alone cannot tell it.
    Vutuv.Activity.broadcast(
      user_id,
      {:engagement_changed, %{kind: kind, post_id: post_id, active?: active?}}
    )
  end

  ## Reading

  @doc """
  Full-text search over post bodies, best match first (ties: newest first).

  Search results are shown to logged-out visitors too, so only posts every
  visitor may read can surface: any denial, a frozen post, an unactivated
  or moderation-hidden author all exclude one. Matching uses the Postgres-
  generated `search_tsv` column with `websearch_to_tsquery` ('simple'
  config, no language stemming — bodies are mixed German/English), so plain
  words, "quoted phrases" and `-exclusions` all work and garbage never
  raises. Authors come preloaded.

  Options:

    * `:tag` — also require a tag whose name or slug matches the string
      (issue #946: the `tag:` search operator finds posts, not just people).
      Combines with the body query (AND); with an empty body it becomes a
      pure tag listing (newest first). Substring by default, equality when
      `:exact` is set.
    * `:exact` — the `tag:` match is equality (`"php"` doesn't hit `phpstorm`).
    * `:limit` — result cap (default 25).
  """
  def search_public(value, opts \\ []) when is_binary(value) do
    do_search_public(value, Keyword.get(opts, :tag), opts)
  end

  # Nothing to search: an empty query with no tag filter matches no post
  # (rather than every post). A tag: filter alone is a valid pure listing.
  defp do_search_public("", nil, _opts), do: []

  defp do_search_public(value, tag, opts) do
    limit = Keyword.get(opts, :limit, 25)

    # scope_visible(nil) supplies the three anonymous-visibility conditions
    # (no denials, unfrozen, non-hidden author); only the search-specific
    # filters stay here. Search keeps the stricter `email_confirmed? == true`
    # (not the confirmed-or-legacy-NULL gate) deliberately.
    from(p in Post, as: :post, join: u in assoc(p, :user), where: u.email_confirmed? == true)
    |> filter_body_search(value)
    |> filter_posts_by_tag(tag, Keyword.get(opts, :exact, false))
    |> order_public_search(value)
    |> limit(^limit)
    |> preload([p, u], user: u)
    |> scope_visible(nil)
    |> Repo.all()
  end

  defp filter_body_search(query, ""), do: query

  defp filter_body_search(query, value) do
    where(query, [p], fragment("? @@ websearch_to_tsquery('simple', ?)", p.search_tsv, ^value))
  end

  # Best full-text match first; a tag-only listing (no body query) is newest
  # first, so ranking never collapses every post to the same score.
  defp order_public_search(query, ""), do: order_by(query, [p], desc: p.id)

  defp order_public_search(query, value) do
    order_by(query, [p],
      desc: fragment("ts_rank(?, websearch_to_tsquery('simple', ?))", p.search_tsv, ^value),
      desc: p.id
    )
  end

  # The post side of the `tag:` search operator (issue #946): keep only posts
  # carrying a tag whose name or slug matches. An EXISTS subquery (not a join)
  # so a post with several matching tags is not duplicated. Same match shape as
  # the people-side `Vutuv.Search.filter_tag/3`: substring by default, equality
  # when the query is `exact?`.
  defp filter_posts_by_tag(query, nil, _exact?), do: query

  defp filter_posts_by_tag(query, tag, true) do
    sub =
      from(pt in PostTag,
        join: t in assoc(pt, :tag),
        where:
          pt.post_id == parent_as(:post).id and
            (fragment("lower(?)", t.name) == ^tag or t.slug == ^tag)
      )

    where(query, [], exists(subquery(sub)))
  end

  defp filter_posts_by_tag(query, tag, false) do
    infix = "%" <> escape_like(tag) <> "%"

    sub =
      from(pt in PostTag,
        join: t in assoc(pt, :tag),
        where:
          pt.post_id == parent_as(:post).id and
            (ilike(t.name, ^infix) or ilike(t.slug, ^infix))
      )

    where(query, [], exists(subquery(sub)))
  end

  @doc """
  The public posts carrying `tag`, newest first, for the tag page's "Posts
  with this tag" section (issue #946). Anonymous view: only posts every
  visitor may read surface (`scope_visible(nil)`), same gate as
  `search_public/2`. Matches the exact tag (its id), not a name substring —
  this is "posts filed under this tag", not a search. Preloaded like every
  rendered post.
  """
  def list_tag_posts(%Tag{} = tag, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    from(p in Post,
      join: u in assoc(p, :user),
      join: pt in PostTag,
      on: pt.post_id == p.id,
      where: pt.tag_id == ^tag.id and u.email_confirmed? == true,
      order_by: [desc: p.id],
      limit: ^limit
    )
    |> scope_visible(nil)
    |> Repo.all()
    |> Repo.preload(post_preloads())
  end

  @doc """
  One page of `viewer`'s newsfeed: own posts plus posts **and reposts** of
  followed (activated) authors, visibility-filtered, newest first.

  Entries are maps `%{id:, post:, reposted_by:, reposters:, at:}` — `id` is
  `"post-<id>"` / `"repost-<id>"` (unique per entry, the stream DOM id),
  `reposted_by` the carrying user (or `nil` for original posts), `reposters`
  every reposter the viewer follows plus the viewer themselves (newest first,
  `[]` for original posts — the roster behind the card's avatar stack), `at`
  the feed timestamp (publication or repost time). Posts are preloaded for
  rendering.

  A post appears **once per page**, at its newest event: several followed
  members reposting the same post collapse into one entry, and a repost of a
  post the viewer also follows directly replaces the standalone original
  (`collapse_reposts/1`). Cross-page duplicates are the LiveView's job — the
  cursor merge can't see previous pages.

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

    entries =
      page.entries
      |> hydrate_posts()
      |> collapse_threads()
      |> collapse_reposts()
      |> attach_reposters(viewer)

    %{page | entries: entries}
  end

  defp feed_post_items(%User{id: viewer_id} = viewer, fetch_n, cursor) do
    from(p in Post,
      join: u in assoc(p, :user),
      where: p.user_id == ^viewer_id or p.user_id in subquery(followees_of(viewer_id)),
      where: p.user_id == ^viewer_id or account_confirmed_row(u),
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
      where: r.user_id == ^viewer_id or account_confirmed_row(reposter),
      where: p.user_id == ^viewer_id or account_confirmed_row(u),
      # A third party's repost must not carry a blocked author's post into
      # the viewer's feed (the direct path is already cut: blocking severed
      # the follow).
      where: p.user_id not in subquery(blocked_either_way(viewer_id)),
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
    # Muted follows stay in place (the relationship and any "vernetzt" status
    # are untouched) but their author's posts drop out of the viewer's feed.
    from(c in Follow,
      where: c.follower_id == ^viewer_id and c.muted == false,
      select: c.followee_id
    )
  end

  # Everyone with a block either way relative to `user_id` (feed exclusion).
  # The "either direction" filter is owned by Vutuv.Social; this only adds the
  # select that returns the *other* party's id for the `NOT IN` subquery.
  defp blocked_either_way(user_id) do
    Vutuv.Social.blocks_involving(user_id)
    |> select(
      [b],
      fragment(
        "CASE WHEN ? = ? THEN ? ELSE ? END",
        b.blocker_id,
        type(^user_id, Vutuv.UUIDv7),
        b.blocked_id,
        b.blocker_id
      )
    )
  end

  # Whether a block stands between `user` and the post's author (either
  # direction). Own posts are never "blocked".
  defp blocked?(%User{id: user_id}, %Post{user_id: author_id}) do
    user_id != author_id and Vutuv.Social.blocked_between?(user_id, author_id)
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

  # A reply renders as a conversation: the posts it answers are stacked above it
  # as full cards (`<.post_thread_entry>`). So when several posts of one thread
  # land on the same page they must collapse into a *single* feed entry —
  # otherwise each post shows both on its own and nested under its reply.
  #
  # A thread is not always a line. When one post is answered by two replies (a
  # branch) and both land on the page, walking strictly up each leaf gave each
  # branch the same shared ancestors, so the whole conversation rendered once per
  # branch — the thread appeared twice in the feed. So group the present
  # (non-repost) post entries into threads by their topmost reachable post (the
  # anchor), and per thread keep exactly one carrier entry — its newest post —
  # annotated with every *other* present thread post as its oldest-first
  # `:ancestors`. Replies are always newer than the posts they answer, so oldest
  # -first is a valid nesting order (a parent always precedes its children) and
  # the branch siblings simply stack in time order; the whole thread renders
  # once, no matter how many posts, authors or branches it spans.
  #
  # The chain to each anchor is walked one link at a time through the entries
  # themselves (each carries its direct parent in the preloaded `reply_ref`), so
  # it reaches as far up as its posts are present on the page; the first parent
  # that is not an entry is kept as the single nested context above the anchor
  # (its own parent is not preloaded). Reposts always render standalone, so they
  # are never grouped, dropped, or made a carrier.
  defp collapse_threads(entries) do
    by_id =
      for %{reposted_by: nil, post: %{id: id} = post} <- entries, into: %{}, do: {id, post}

    # Oldest-first path (topmost context down to the post itself) for every
    # present post entry; its head is the thread anchor.
    paths =
      Map.new(by_id, fn {id, post} -> {id, ancestor_chain(post, by_id) ++ [post]} end)

    # Every post of each thread, deduped and oldest-first, keyed by anchor id.
    thread_posts =
      paths
      |> Enum.group_by(fn {_id, path} -> hd(path).id end, fn {_id, path} -> path end)
      |> Map.new(fn {anchor, branch_paths} ->
        posts =
          branch_paths
          |> Enum.concat()
          |> Enum.uniq_by(& &1.id)
          |> Enum.sort_by(& &1.inserted_at, NaiveDateTime)

        {anchor, posts}
      end)

    # The one carrier entry per thread: its newest post (the last, oldest-first).
    carrier_ids =
      MapSet.new(thread_posts, fn {_anchor, posts} -> List.last(posts).id end)

    Enum.flat_map(entries, fn
      %{reposted_by: reposted_by} = entry when not is_nil(reposted_by) ->
        # Reposts render standalone; keep the one-level parent nesting they had.
        [Map.put(entry, :ancestors, ancestor_chain(entry.post, by_id))]

      %{post: post} = entry ->
        if MapSet.member?(carrier_ids, post.id) do
          anchor = hd(Map.fetch!(paths, post.id)).id
          ancestors = thread_posts |> Map.fetch!(anchor) |> Enum.drop(-1)
          [Map.put(entry, :ancestors, ancestors)]
        else
          # A non-carrier thread member: it renders inside the carrier's chain.
          []
        end
    end)
  end

  # The same post can land on one page several times: through more than one
  # followed reposter, and through its standalone original entry when the
  # viewer follows the author too. A feed shows a post once, so collapse the
  # duplicates onto the newest occurrence — the event that put it this high on
  # the page. Entries arrive newest-first and a repost always postdates its
  # post's publication, so `uniq_by` keeps the newest repost and drops both
  # older reposts and the standalone original.
  #
  # Two thread exceptions keep a conversation whole:
  #   * a post rendering as a full card inside a collapsed thread (carrier or
  #     nested ancestor) stays with its conversation — the competing repost
  #     entry drops instead, since deduping the thread away would take the
  #     other posts of the conversation with it;
  #   * conversely, a kept repost entry nests its own present ancestors
  #     (`collapse_threads/1` gives reposts the one-level chain), so a
  #     *standalone* original already shown inside that repost card drops.
  defp collapse_reposts(entries) do
    threaded_ids =
      for %{reposted_by: nil, ancestors: [_ | _]} = entry <- entries,
          post <- [entry.post | entry.ancestors],
          into: MapSet.new(),
          do: post.id

    kept =
      entries
      |> Enum.reject(&(&1.reposted_by != nil and MapSet.member?(threaded_ids, &1.post.id)))
      |> Enum.uniq_by(& &1.post.id)

    repost_nested_ids =
      for %{reposted_by: %User{}} = entry <- kept,
          post <- entry.ancestors,
          into: MapSet.new(),
          do: post.id

    Enum.reject(kept, fn entry ->
      entry.reposted_by == nil and entry.ancestors == [] and
        MapSet.member?(repost_nested_ids, entry.post.id)
    end)
  end

  # Completes each repost-carried entry with every reposter the viewer follows
  # (plus the viewer themselves), newest first — one indexed query for the
  # whole page, regardless of which repost happened to carry the entry. The
  # roster is deliberately follow-scoped: it explains why the post is in
  # *this* feed; the global repost count already lives on the action bar.
  defp attach_reposters(entries, %User{} = viewer) do
    post_ids = for %{reposted_by: %User{}} = entry <- entries, do: entry.post.id
    rosters = reposter_rosters(post_ids, viewer)

    Enum.map(entries, fn
      %{reposted_by: %User{}} = entry ->
        reposters = Map.get(rosters, entry.post.id, [entry.reposted_by])
        entry |> Map.put(:reposters, reposters) |> Map.put(:reposted_by, hd(reposters))

      entry ->
        Map.put(entry, :reposters, [])
    end)
  end

  defp reposter_rosters([], _viewer), do: %{}

  defp reposter_rosters(post_ids, %User{id: viewer_id}) do
    from(r in PostRepost,
      join: u in User,
      on: u.id == r.user_id,
      where: r.post_id in ^post_ids,
      where: r.user_id == ^viewer_id or r.user_id in subquery(followees_of(viewer_id)),
      where: r.user_id == ^viewer_id or account_confirmed_row(u),
      order_by: [desc: r.inserted_at, desc: r.id],
      select: {r.post_id, u}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # The posts `post` answers, oldest first. Walk up the reply chain, preferring
  # the fully-preloaded entry copy of each parent (which carries its own
  # `reply_ref`) so the walk can continue past it; stop at a root or at the first
  # parent that is not itself an entry (its parent is not preloaded — one level
  # only there). Reply parents are always older posts, so the walk can't cycle.
  defp ancestor_chain(post, by_id, acc \\ []) do
    case reply_ref_state(post) do
      {:parent, parent} ->
        case Map.get(by_id, parent.id) do
          nil -> [parent | acc]
          entry_parent -> ancestor_chain(entry_parent, by_id, [entry_parent | acc])
        end

      _ ->
        acc
    end
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
    |> collapse_threads()
  end

  @doc "How many timeline entries of `author` `viewer` may see (the \"View all\" label)."
  def count_author_posts(%User{} = author, viewer) do
    author |> author_timeline_query(viewer) |> Repo.aggregate(:count)
  end

  @doc """
  The newest anonymous-visible posts for the RSS feeds: `author`'s own
  original posts (reposts are engagement rows, so they never appear), or
  `:all` for the site-wide feed. The aggregate feed carries one all-yes
  Content-Signal and cannot signal per item, so it lists only members who
  opted out of nothing — neither of search engines (`noindex?`) nor of AI
  use (`noai?`); an opted-out member's posts still serve through their own
  feed, which signals their choices per response.
  Preloaded like every rendered post; ordered by creation (the UUID v7 id).
  """
  def recent_public_posts(author_or_all, opts \\ [])

  def recent_public_posts(%User{id: author_id}, opts) do
    Post
    |> where([p], p.user_id == ^author_id)
    |> recent_public(opts)
  end

  def recent_public_posts(:all, opts) do
    Post
    |> join(:inner, [p], u in assoc(p, :user))
    |> where([p, u], u.email_confirmed? and not u.noindex? and not u.noai?)
    |> recent_public(opts)
  end

  defp recent_public(query, opts) do
    query
    |> scope_visible(nil)
    |> order_by([p], desc: p.id)
    |> limit(^Keyword.get(opts, :limit, 20))
    |> Repo.all()
    |> Repo.preload(post_preloads())
  end

  @discover_limit 5
  @discover_pool 100

  @doc """
  A random handful of recent public posts for the feed's discovery rail:
  posts by members who share `viewer`'s language but whom the viewer does
  not follow — the post-shaped sibling of the "Who to follow" suggestions.

  One post per author (their newest eligible one), drawn at random from the
  `@discover_pool` newest such posts, so the rail surfaces different voices
  on every draw while staying "new". Language matches on `users.locale` with
  the empty value counting as English, mirroring `VutuvWeb.LiveLocale`'s
  fallback. Replies (confusing without their thread) and image-only posts
  (nothing to excerpt in a compact row) are skipped; a *muted* follow is
  still a follow, so those authors stay excluded too. Preloaded like every
  rendered post.
  """
  def discover_posts(%User{} = viewer, opts \\ []) do
    limit = Keyword.get(opts, :limit, @discover_limit)
    locale = locale_or_english(viewer.locale)

    newest_per_author =
      from(p in Post,
        join: u in assoc(p, :user),
        left_join: r in assoc(p, :reply_ref),
        where: is_nil(r.id),
        where: fragment("COALESCE(NULLIF(?, ''), 'en')", u.locale) == ^locale,
        where: p.user_id != ^viewer.id,
        where: p.user_id not in subquery(all_followees_of(viewer.id)),
        where: p.user_id not in subquery(blocked_either_way(viewer.id)),
        where: account_confirmed_row(u),
        where: p.body != "",
        distinct: p.user_id,
        order_by: [asc: p.user_id, desc: p.id],
        select: %{id: p.id}
      )
      |> scope_visible(nil)

    pool =
      from(s in subquery(newest_per_author),
        order_by: [desc: s.id],
        limit: @discover_pool,
        select: %{id: s.id}
      )

    ids =
      from(s in subquery(pool),
        order_by: fragment("random()"),
        limit: ^limit,
        select: s.id
      )
      |> Repo.all()

    from(p in Post, where: p.id in ^ids)
    |> Repo.all()
    |> Repo.preload(post_preloads())
    # An `id IN` fetch loses the random draw order.
    |> Enum.shuffle()
  end

  defp locale_or_english(locale) when is_binary(locale) and locale != "", do: locale
  defp locale_or_english(_locale), do: "en"

  # Unlike the feed's `followees_of/1`, muted follows count here: muting only
  # silences a followee's posts, it does not turn them back into a stranger
  # worth suggesting.
  defp all_followees_of(viewer_id) do
    from(c in Follow, where: c.follower_id == ^viewer_id, select: c.followee_id)
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
  # reposts (dated by the repost), each visibility-scoped to `viewer` — as one
  # subquery the callers count, period-scope and page like a plain table.
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
          on_date:
            fragment("((? AT TIME ZONE 'UTC') AT TIME ZONE 'Europe/Berlin')::date", r.inserted_at)
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
  One page of the posts `user` liked, for the saved-items hub. See
  `engaged_posts_page/3` for `opts` (`:search`, `:sort`, `:limit`, `:offset`).
  Visibility-filtered at read time (a since-restricted post drops out).
  """
  def liked_posts_page(%User{} = user, opts \\ []), do: engaged_posts_page(PostLike, user, opts)

  @doc "One page of the posts `user` bookmarked — see `liked_posts_page/2`."
  def bookmarked_posts_page(%User{} = user, opts \\ []),
    do: engaged_posts_page(PostBookmark, user, opts)

  # `opts`: `:search` (matches post body and author name, case-insensitive),
  # `:sort` (`:recent` default newest-saved-first | `:oldest` | `:name` by
  # author), `:limit` (default #{@default_feed_limit}) and `:offset`. Offset
  # paginated (a text filter plus three sort orders would need a cursor that
  # encodes every order; the saved lists are personal and modest), returning
  # `%{entries: [%Post{}], more?:, next_offset:}` — pass `:offset` back for the
  # next page. Entries are plain preloaded posts.
  defp engaged_posts_page(schema, %User{id: user_id} = user, opts) do
    limit = Keyword.get(opts, :limit, @default_feed_limit)
    offset = Keyword.get(opts, :offset, 0)
    sort = Keyword.get(opts, :sort, :recent)
    search = opts |> Keyword.get(:search) |> normalize_search()

    rows =
      from(p in Post,
        join: e in ^schema,
        as: :engagement,
        on: e.post_id == p.id,
        join: a in assoc(p, :user),
        as: :author,
        where: e.user_id == ^user_id,
        select: {p, e.inserted_at, e.id}
      )
      |> scope_visible(user)
      |> filter_engaged_search(search)
      |> order_engaged(sort)
      |> limit(^(limit + 1))
      |> offset(^offset)
      |> Repo.all()

    page = Pages.offset_page(rows, limit, offset)
    posts = page.entries |> Enum.map(&elem(&1, 0)) |> Repo.preload(post_preloads())

    %{page | entries: posts}
  end

  defp filter_engaged_search(query, nil), do: query

  defp filter_engaged_search(query, term) do
    pattern = "%" <> escape_like(term) <> "%"

    from([p, author: a] in query,
      where: ilike(p.body, ^pattern) or name_ilike(a.first_name, a.last_name, ^pattern)
    )
  end

  defp order_engaged(query, :oldest),
    do: order_by(query, [engagement: e], asc: e.inserted_at, asc: e.id)

  defp order_engaged(query, :name),
    do: order_by(query, [author: a], asc: a.first_name, asc: a.last_name, asc: a.id)

  defp order_engaged(query, _recent),
    do: order_by(query, [engagement: e], desc: e.inserted_at, desc: e.id)

  @doc "The permalink lookup: `author`'s preloaded post by id, or `nil`."
  def get_post(%User{id: author_id}, id) do
    UUIDv7.with_cast(id, fn id ->
      from(p in Post, where: p.user_id == ^author_id and p.id == ^id)
      |> Repo.one()
      |> preload_post()
    end)
  end

  @doc "A preloaded post by id, or `nil` (live-feed pill, edit page)."
  def get_post(id) do
    # with_cast: a garbage id in /posts/:id/edit is a nil (404), not a 500.
    UUIDv7.with_cast(id, &(Post |> Repo.get(&1) |> preload_post()))
  end

  @doc """
  The given post ids **visible to `viewer`** as a `%{id => %Post{}}` map with
  `:user` preloaded, for building the notification-page post previews (the shared
  `<.post_preview>` needs the author + permalink, not just the body) in one round
  trip. Missing, deleted or denied ids are simply absent; a `nil`/empty id list
  makes no query. `viewer`'s own posts always pass (so the recipient's own post
  that a reply/like is about is always quotable), while another member's post (a
  reply quoted alongside it) passes only when the deny-based visibility rules
  would show it, so a restricted reply never leaks through the notification.
  """
  def visible_posts_by_ids(viewer, ids) do
    ids = ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    if ids == [] do
      %{}
    else
      from(p in Post, where: p.id in ^ids)
      |> scope_visible(viewer)
      |> Repo.all()
      |> Repo.preload(:user)
      |> Map.new(&{&1.id, &1})
    end
  end

  @doc """
  Classifies a post's reply parent (from its preloaded `reply_ref`) into one of
  `{:parent, parent_post}` (the parent still exists), `{:author_only, author}`
  (the parent post is gone but its author remains), `:gone` (author gone too),
  or `nil` (not a reply). The API (`PostJSON`), the agent docs (`PostDoc`) and
  the post card all render from this, so they can't disagree on what a reply
  points at. An un-preloaded `reply_ref` is a truthy `NotLoaded`, hence the
  struct matches.
  """
  def reply_ref_state(%Post{reply_ref: %PostReply{} = ref}) do
    cond do
      match?(%Post{}, ref.parent_post) -> {:parent, ref.parent_post}
      match?(%User{}, ref.parent_author) -> {:author_only, ref.parent_author}
      true -> :gone
    end
  end

  def reply_ref_state(_post), do: nil

  defp preload_post(nil), do: nil
  defp preload_post(%Post{} = post), do: Repo.preload(post, post_preloads(), force: true)

  defp post_preloads do
    # denials with group/denied_user: the author-facing audience display
    # names them (never shown to other viewers). reply_ref goes exactly one
    # level deep (the banner names the direct parent only) — preloading the
    # parent's own reply_ref would recurse. The parent carries :images + :tags
    # too: the feed/profile thread nests it as a full post card (its own action
    # bar, images, tags), not just a one-line excerpt.
    [
      :user,
      :images,
      # The auto link screenshot rendered beside a single-URL post (nil for
      # every other post); the card shows it only once `status: "ready"`.
      :screenshot,
      denials: [:denied_user],
      tags: from(t in Tag, order_by: t.name),
      reply_ref: [
        :parent_author,
        parent_post: [:user, :images, :screenshot, tags: from(t in Tag, order_by: t.name)]
      ]
    ]
  end

  @doc """
  The root-relative permalink path, e.g.
  `/stefan/posts/019748c8-1a2b-7c3d-8e4f-5a6b7c8d9e0f`. Lives under the
  author archive (`/:slug/posts`), whose year/month/day pages stay
  date-scoped index views. Requires `:user` to be preloaded.
  """
  def path(%Post{user: %User{} = user, id: id}) do
    "/#{user.username}/posts/#{id}"
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
        {:ok, meta} -> insert_scanned_image(user, token, meta)
        {:error, _} = error -> error
      end
    end
  end

  # Fresh images start in AI-moderation limbo (owner-only, placecard for
  # everyone else) until the scan releases or deletes them.
  defp insert_scanned_image(user, token, meta) do
    insert =
      %PostImage{
        user_id: user.id,
        token: token,
        moderation: ImageScans.initial_state()
      }
      |> Ecto.Changeset.change(meta)
      |> Repo.insert()

    with {:ok, image} <- insert do
      ImageScans.enqueue("post_image", image.id, user.id)
      {:ok, image}
    end
  end

  def update_image_alt(%PostImage{} = image, alt) do
    image |> PostImage.alt_changeset(%{alt: alt}) |> Repo.update()
  end

  @doc """
  Only the AI-released images of a post — what every anonymous/public
  rendering (agent docs, JSON-LD, OpenGraph, the API) may show. The owner's
  in-limbo view is the post card's business (`VutuvWeb.PostComponents`).
  """
  def released_images(%Post{images: images}), do: released_images(images)

  def released_images(images) when is_list(images),
    do: Enum.filter(images, &ImageScans.released?(&1.moderation))

  def released_images(_not_loaded), do: []

  @doc "Deletes a pending (unattached) image: row and files."
  def delete_pending_image(%PostImage{post_id: nil} = image) do
    delete_if_pending(image)
    :ok
  end

  # Deletes the row only while it is still pending — the `is_nil(post_id)` guard
  # is re-checked inside the DELETE so we never race a concurrent attach — and
  # drops its files when this call is the one that removed it. Returns whether
  # this call performed the delete.
  defp delete_if_pending(%PostImage{} = image) do
    {count, _} =
      Repo.delete_all(from(i in PostImage, where: i.id == ^image.id and is_nil(i.post_id)))

    if count == 1, do: PostImageStore.delete(image.token)
    count == 1
  end

  @doc "The image behind a proxy token, with its post and owner preloaded; `nil` when unknown."
  def get_image_by_token(token) when is_binary(token) do
    PostImage
    |> Repo.get_by(token: token)
    |> case do
      nil -> nil
      # :user lets the proxy name the download after the owner's handle
      # (Content-Disposition); :post drives the visibility check, and its :user
      # (the author) lets the moderation-hidden check read the loaded struct
      # instead of re-fetching the author on every image request.
      image -> Repo.preload(image, [:user, post: :user])
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

    # AI-moderation limbo: until released, the bytes are owner/admin-only
    # (everyone else gets the gallery placecard, and this proxy 404s).
    visible_to?(post, viewer) and
      (ImageScans.released?(image.moderation) or privileged_image_viewer?(image, viewer))
  end

  defp privileged_image_viewer?(%PostImage{user_id: uploader_id}, %User{id: uploader_id}),
    do: true

  defp privileged_image_viewer?(_image, %User{admin?: true}), do: true
  defp privileged_image_viewer?(_image, _viewer), do: false

  @doc """
  Removes pending images older than a day (abandoned composer sessions),
  files included. Returns the number of swept images.
  """
  def sweep_pending_images(max_age_hours \\ @pending_max_age_hours) do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -max_age_hours * 3600)

    from(i in PostImage, where: is_nil(i.post_id) and i.inserted_at < ^cutoff)
    |> Repo.all()
    |> Enum.count(&delete_if_pending/1)
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
          where: account_confirmed_row(u),
          where: name_ilike(u.first_name, u.last_name, ^pattern) or ilike(u.username, ^pattern),
          order_by: [u.first_name, u.last_name],
          limit: ^limit
        )
      )
    end
  end

  ## Tags

  defp parse_tag_values(nil), do: []

  # The composer field shares the tags-page tokenizer: an unquoted comma or
  # space separates ("elixir Phoenix, Ecto" is three tags) while a quoted
  # phrase stays one multi-word tag ("Ruby on Rails"). Delegates to the list
  # head below for the dedupe + cap.
  defp parse_tag_values(values) when is_binary(values),
    do: values |> Tags.parse_tag_names() |> parse_tag_values()

  # Tag.normalize_value strips a leading `#` (the hashtag form), so "#Elixir"
  # becomes "Elixir" and dedupes/links against the bare tag; a bare "#" drops.
  defp parse_tag_values(values) when is_list(values) do
    values
    |> Enum.map(&Tag.normalize_value/1)
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
    case Tag.find_by_value(value) do
      %Tag{id: id} -> id
      nil -> insert_tag_for_value(value)
    end
  end

  defp insert_tag_for_value(value) do
    case Repo.insert(Tag.changeset(%Tag{}, %{"value" => value})) do
      {:ok, tag} -> tag.id
      # Lost a race or invalid value — one more lookup, then give up.
      {:error, _} -> with(%Tag{id: id} <- Tag.find_by_value(value), do: id)
    end
  end

  ## Broadcasts

  defp broadcast_new_post(%Post{} = post) do
    event = {:new_post, %{post_id: post.id, author_id: post.user_id}}
    broadcast_to_followers(post.user_id, event)
  end

  @doc """
  Removes a post's auto-captured link screenshot on the author's request (the
  post edit page: a bad capture, e.g. one dominated by a cookie banner). The
  screenshot is tombstoned so it stops rendering and is not re-captured on a
  plain re-save (`Vutuv.Posts.Screenshots.dismiss/1`), and open feeds/profiles
  drop it live. Returns `{:ok, post}` with `:screenshot` reloaded; a no-op (also
  `{:ok, post}`) when the post carries no screenshot.
  """
  def dismiss_screenshot(%Post{} = post) do
    post = Repo.preload(post, :screenshot)

    case post.screenshot do
      %PostScreenshot{} = post_screenshot ->
        {:ok, _dismissed} = Screenshots.dismiss(post_screenshot)
        broadcast_screenshot_removed(post.id)
        {:ok, Repo.preload(post, :screenshot, force: true)}

      _none ->
        {:ok, post}
    end
  end

  @doc """
  Tells open clients a post's link screenshot is now ready to render, so an
  already-loaded feed/profile upgrades the card with no reload. Fans out to the
  same recipients as `{:new_post, …}` — the author's own topic (which their
  profile page subscribes to) and every follower's feed topic — via the shared
  `Vutuv.Posts.Screenshots` worker on capture success. A no-op for a post that
  vanished before the capture finished.
  """
  def broadcast_screenshot_ready(post_id) when is_binary(post_id) do
    case Repo.get(Post, post_id) do
      nil ->
        :ok

      %Post{user_id: author_id} ->
        event = {:post_screenshot_ready, %{post_id: post_id, author_id: author_id}}
        broadcast_to_followers(author_id, event)
    end
  end

  @doc """
  The counterpart to `broadcast_screenshot_ready/1`: the author removed a post's
  auto link screenshot, so open feeds/profiles drop it from the card with no
  reload. Fans out to the same recipients (author topic + followers' feeds).
  """
  def broadcast_screenshot_removed(post_id) when is_binary(post_id) do
    case Repo.get(Post, post_id) do
      nil ->
        :ok

      %Post{user_id: author_id} ->
        event = {:post_screenshot_removed, %{post_id: post_id, author_id: author_id}}
        broadcast_to_followers(author_id, event)
    end
  end

  # Enqueue / refresh / drop the post's link screenshot to match its current
  # body and images, then poke the worker to capture it now. Gated by
  # `:generate_screenshots` so an air-gapped install queues nothing (and the
  # test suite creates no rows unless it opts in).
  defp reconcile_screenshot(%Post{} = post) do
    if Application.get_env(:vutuv, :generate_screenshots, true) do
      Screenshots.reconcile(post)
      ScreenshotWorker.nudge()
    end

    :ok
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
      Vutuv.Activity.notify_reply(parent.user_id, reply.user, parent.id, reply.id)
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
    broadcast_counters(parent_id)
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
