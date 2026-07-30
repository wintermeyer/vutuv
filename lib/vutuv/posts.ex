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

  **Photo posts** (issue #1104) are ordinary posts, not a second kind: several
  photos lay themselves out as a bento mosaic in the feed, each carries an
  optional caption, and the two per-photo opt-ins (camera panel, original
  download) live on `Vutuv.Posts.PostImage`. The post carries one
  `Vutuv.Posts.PhotoLicense` for the set, and the author's last pick is
  remembered on their account as the next post's pre-selection.

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
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.PostRepost, as: FediversePostRepost
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Mentions
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Pages
  alias Vutuv.PostImageStore
  alias Vutuv.Posts.PhotoLicense
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostBookmark
  alias Vutuv.Posts.PostDenial
  alias Vutuv.Posts.PostDraft
  alias Vutuv.Posts.PostImage
  alias Vutuv.Posts.PostLike
  alias Vutuv.Posts.PostMention
  alias Vutuv.Posts.PostRemoteReply
  alias Vutuv.Posts.PostReply
  alias Vutuv.Posts.PostRepost
  alias Vutuv.Posts.PostReview
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Posts.PostTag
  alias Vutuv.Posts.ReviewCovers
  alias Vutuv.Posts.Screenshots
  alias Vutuv.Posts.ScreenshotWorker
  alias Vutuv.Repo
  alias Vutuv.Social.Follow
  alias Vutuv.Tags
  alias Vutuv.Tags.Tag
  alias Vutuv.Uploads.Crop
  alias Vutuv.UUIDv7
  alias Vutuv.WebAddress

  @default_feed_limit 20
  @default_profile_limit 3
  @default_thread_limit 100
  # The permalink conversation's cap (issue #1006): strictly above the
  # one-level reply cap plus the post itself, so the whole-thread page can
  # never show fewer posts than the old post-plus-direct-replies page did.
  @default_conversation_limit 200
  # The permalink's conversation window (issue #1033 follow-up): a thread at
  # most this big renders whole; a bigger one opens as a window around the
  # permalinked post and grows on demand (VutuvWeb.PostLive.Thread).
  @thread_all_limit 25
  # Nearest ancestors first shown above the focus, and how many more each
  # "show earlier" click reveals.
  @thread_context_ancestors 3
  @thread_ancestor_page 10
  # Posts of the focus's own reply subtree first shown below it, and how many
  # more each "show more" click reveals.
  @thread_reply_page 20
  # Hard cap on the id-only skeleton walk of one conversation: tree math stays
  # bounded even on a degenerate thread; the page never renders more than the
  # window anyway.
  @thread_skeleton_limit 1000
  @pending_max_age_hours 24
  @max_tags 5
  @tag_posts_per_page 20

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
    with {:ok, denials} <- normalize_denials(author.id, fetch(attrs, :denials) || []) do
      do_create_post(author, attrs, denials, nil)
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
  def create_reply(%User{} = author, %Post{} = parent, attrs),
    do: do_create_reply(author, parent, attrs, nil)

  @doc """
  Creates a reply to a reply that came from **another network** (issue #1070).

  Underneath it is an ordinary `create_reply/3` to the vutuv post the remote note
  answers, so local threading, the parent-author notification, the public reply
  count and the edit window behave exactly as for any other reply. On top it
  writes the `Vutuv.Posts.PostRemoteReply` sidecar, which is what makes the
  outgoing activity carry an `inReplyTo` into that other network, a `Mention` of
  the person answered, and their inbox among its recipients.

  Any member may answer a note, not only the author of the post it sits under, so
  long as they federate: `Vutuv.Fediverse.check_remote_reply/2` holds that gate
  (plus the installation switch, public-notes-only, the operator blocklist and an
  outbound rate limit) and names which one refused, so the caller can tell a
  member who simply has not switched federation on from a hard no.
  """
  def create_remote_reply(%User{} = author, %Note{} = note, attrs) do
    with :ok <- Vutuv.Fediverse.check_remote_reply(author, note),
         :ok <- Vutuv.Fediverse.claim_reply_budget(author),
         %Post{} = parent <- get_post(note.post_id) do
      do_create_reply(author, parent, attrs, note)
    else
      nil -> {:error, :not_visible}
      {:error, _} = error -> error
    end
  end

  @doc """
  Creates a member's answer to a post by an account they follow on another
  network (issue #1165).

  Unlike `create_remote_reply/3` this is **not** a reply to anything here: the
  post being answered lives entirely on somebody else's server, so what is
  created is a top-level vutuv post carrying the `Vutuv.Posts.PostRemoteReply`
  sidecar. That sidecar is what makes the outgoing `Create(Note)` thread under
  their post over there — `inReplyTo`, the author in `cc`, and a `Mention` built
  from the stored actor URI rather than from anything the member typed.

  Every gate is `Vutuv.Fediverse.check_remote_post_reply/2`'s, including the one
  that makes this narrower than answering a reply: a followers-only post cannot
  be answered at all, because the answer is public here and republishing the
  audience its author chose is not ours to do.

  Denials are dropped (an answer that federates is public by definition), the
  same call `do_create_reply/4` makes.
  """
  def create_remote_post_reply(%User{} = author, %RemotePost{} = remote_post, attrs) do
    # Re-read first, and gate on what comes back. The struct in hand was
    # captured when the composer opened, and a member types for minutes: in that
    # time the row can be **gone** (expiry, an upstream `Delete`, another
    # member's report, an instance block), which would hit the sidecar's foreign
    # key and take the LiveView down; or its **audience can have narrowed**, in
    # which case the stale struct still says public and this feature's one rule
    # — no public answer to a followers-only post — would be bypassed by simply
    # having the form open when the author changed their mind.
    with %RemotePost{} = remote_post <- Vutuv.Fediverse.reload_remote_post(remote_post),
         :ok <- Vutuv.Fediverse.check_remote_post_reply(author, remote_post),
         :ok <- Vutuv.Fediverse.claim_reply_budget(author) do
      do_create_post(author, attrs, [], remote_post)
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  # Creating a post that answers nothing on this site: the feed's own composer
  # (`create_post/2`, with the audience its author picked) and the answer to a
  # post on another network (issue #1165 — public by definition, so no denials,
  # and carrying the sidecar `remote_target` writes instead). Everything after
  # the insert is the same act either way, so it is written once here.
  defp do_create_post(%User{} = author, attrs, denials, remote_target) do
    image_ids = parse_ids(fetch(attrs, :image_ids) || [])

    with :ok <- check_image_count(image_ids),
         {:ok, changeset} <- build_changeset(%Post{user_id: author.id}, attrs, denials, image_ids) do
      case insert_post(changeset, image_ids, nil, remote_target) do
        {:ok, post} ->
          post = preload_post(post)
          broadcast_new_post(post)
          # A photo post's license becomes the author's pre-selection next time.
          remember_license(author, post)
          # Everyone the body names by @handle is told they were named.
          sync_mentions(post)
          # Follow-only federation: a federating author's public post goes
          # out to their remote followers (no-op for everyone else).
          Vutuv.Fediverse.federate_new_post(post)
          # A single-URL, image-less post gets a link screenshot, captured off
          # the request path via the durable queue.
          reconcile_screenshot(post)
          # A book review with an ISBN gets its cover fetched off the request
          # path (no-op for every other post).
          ReviewCovers.reconcile(post)
          {:ok, post}

        {:error, _} = error ->
          error
      end
    end
  end

  defp do_create_reply(%User{} = author, %Post{} = parent, attrs, note) do
    image_ids = parse_ids(fetch(attrs, :image_ids) || [])

    with :ok <- check_reply_allowed(author, parent),
         :ok <- check_image_count(image_ids),
         # A reply has no audience of its own: it inherits the parent's, which
         # check_reply_allowed already constrains to public. Any denials in the
         # params are dropped, so the public reply count and the parent-author
         # notification only ever concern content the author can see (issue #774).
         {:ok, changeset} <- build_changeset(%Post{user_id: author.id}, attrs, [], image_ids) do
      case insert_post(changeset, image_ids, parent, note) do
        {:ok, post} ->
          post = preload_post(post)
          # Answering a post is the clearest possible proof of having read it,
          # so any notification about the parent stops counting as unread.
          Vutuv.Activity.mark_post_seen(author.id, parent.id)
          broadcast_new_post(post)
          broadcast_reply(parent, post)
          sync_mentions(post)
          Vutuv.Fediverse.federate_new_post(post)
          reconcile_screenshot(post)
          ReviewCovers.reconcile(post)
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

  Editing closes with the edit window (`editable?/1`): `{:error,
  :edit_window_closed}` once the post is older than `edit_window_minutes/0`,
  `{:error, :edit_engaged}` once someone liked, reposted or answered it.
  """
  def update_post(%Post{} = post, attrs) do
    post = Repo.preload(post, [:denials, :post_tags, :images, :review])
    image_ids = parse_ids(fetch(attrs, :image_ids) || [])

    with :ok <- check_edit_open(post),
         {:ok, denials} <- normalize_denials(post.user_id, fetch(attrs, :denials) || []),
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
        # An edit can attach a fresh photo (holding the post again) or drop the
        # last unchecked one (releasing it), so the hold is recomputed here
        # too — and a release fans the post out, since for its followers this
        # is the moment it appears.
        {changed?, pending?} = recompute_images_pending(updated.id)
        # preload/2 keeps the struct's own columns, so the fresh hold is put
        # back on by hand — the composer navigates to a card built from this.
        updated = %{preload_post(updated) | images_pending?: pending?}

        if changed? and not pending?,
          do: broadcast_new_post_to_followers(updated.id, updated.user_id)

        remember_license(updated.user, updated)
        # The edit can add a name, drop one, or (by changing the audience)
        # move a named member out of the post's reach: re-derive the set.
        sync_mentions(updated)
        # Remote copies follow the edit (Update) — or, if the audience just
        # closed, leave public view (Delete, best effort).
        Vutuv.Fediverse.federate_post_update(updated)
        # An edit can add/remove the qualifying URL or an image: enqueue, refresh
        # or drop the link screenshot to match.
        reconcile_screenshot(updated)
        # …and change the reviewed ISBN, which re-fetches the cover.
        ReviewCovers.reconcile(updated)
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
    # `:remote_reply_ref` is loaded before the delete on purpose: the sidecar row
    # cascades away with the post, but the Delete(Tombstone) still has to reach
    # the person on the other network who was answered (issue #1070). The
    # in-memory struct is the only place that address is left afterwards.
    post = Repo.preload(post, [:images, :screenshot, :review, :remote_reply_ref])
    parent_id = reply_parent_id(post.id)

    case Repo.delete(post) do
      {:ok, deleted} ->
        Enum.each(post.images, &PostImageStore.delete(&1.token))
        # The post_screenshots row cascades with the post; its stored files do
        # not, so purge them explicitly (a no-op when there was no screenshot).
        if post.screenshot, do: Screenshots.delete(post.screenshot)
        # Same for a book review's fetched cover files.
        if post.review, do: ReviewCovers.delete_files(post.review)
        broadcast_post_deleted(post.id, post.user_id)
        if parent_id, do: broadcast_reply_count(parent_id)
        # Deleting reported content settles its moderation case.
        Vutuv.Moderation.content_deleted(deleted)
        # Remote copies get a Delete(Tombstone) — best effort by protocol. The
        # one revocation chokepoint, shared with the moderation takedowns.
        Vutuv.Fediverse.revoke_post(deleted)
        {:ok, deleted}

      {:error, _} = error ->
        error
    end
  end

  # Body + denials + tags + review in one changeset; images attach separately
  # (they are pre-existing rows, not nested params).
  defp build_changeset(post_or_struct, attrs, denials, image_ids) do
    tag_ids = attrs |> fetch(:tags) |> parse_tag_values() |> tag_ids_for()

    changeset =
      post_or_struct
      |> Post.changeset(post_params(attrs))
      |> Ecto.Changeset.put_assoc(:denials, Enum.map(denials, &struct(PostDenial, &1)))
      |> Ecto.Changeset.put_assoc(:post_tags, Enum.map(tag_ids, &%PostTag{tag_id: &1}))
      |> put_review(post_or_struct, fetch(attrs, :review))
      |> require_content(image_ids)

    if changeset.valid?, do: {:ok, changeset}, else: {:error, changeset}
  end

  # The license key is only put through when the caller sent one, so the API's
  # partial PATCH (and every non-photo save path) leaves a stored license
  # alone instead of resetting it to the default. The bento layout follows the
  # same rule — absent key = untouched; a sent "" clears back to automatic
  # (`GalleryLayout.cast/1` in the changeset maps it to nil).
  defp post_params(attrs) do
    params = %{body: to_string(fetch(attrs, :body) || "")}

    params =
      case fetch(attrs, :license) do
        nil -> params
        license -> Map.put(params, :license, license)
      end

    params =
      case fetch(attrs, :layout) do
        nil -> params
        layout -> Map.put(params, :gallery_layout, layout)
      end

    case fetch(attrs, :fill) do
      nil -> params
      fill -> Map.put(params, :gallery_fill?, fill)
    end
  end

  # The optional review sidecar (Vutuv.Posts.PostReview). Attrs without a
  # :review key leave an existing review untouched (the API's partial PATCH);
  # a blank kind removes it (the composer always submits the kind, so closing
  # the review panel deletes on save); anything else casts onto the existing
  # review (update — preloaded by update_post) or a fresh one (create).
  defp put_review(changeset, _post, nil), do: changeset

  defp put_review(changeset, post, review_attrs) when is_map(review_attrs) do
    case fetch(review_attrs, :kind) do
      blank when blank in [nil, ""] ->
        Ecto.Changeset.put_assoc(changeset, :review, nil)

      _kind ->
        existing =
          case post do
            %Post{review: %PostReview{} = review} -> review
            _post -> %PostReview{}
          end

        Ecto.Changeset.put_assoc(changeset, :review, PostReview.changeset(existing, review_attrs))
    end
  end

  defp put_review(changeset, _post, _other),
    do: Ecto.Changeset.add_error(changeset, :review, "is invalid")

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
  # claims and — for a reply — the PostReply row (plus, when it answers another
  # network, the PostRemoteReply sidecar) in one transaction, so post and
  # references land (or roll back) together.
  defp insert_post(changeset, image_ids, parent, remote_target) do
    Repo.transaction(fn ->
      changeset
      |> Ecto.Changeset.change(published_on: Vutuv.BerlinTime.today())
      |> Repo.insert()
      |> case do
        {:ok, post} ->
          attach_images!(post, image_ids)
          insert_reply_ref!(post, parent)
          insert_remote_reply_ref!(post, remote_target)
          hold_for_image_check!(post)

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  defp insert_remote_reply_ref!(_post, nil), do: :ok

  # Everything delivery needs is copied here now, while the note is still on
  # hand: the note is a cache that expires (or is taken down), and an `Update` or
  # `Delete` of this answer has to keep reaching the person who was answered long
  # after that. Hence the copies, and hence `note_id` nilifying rather than
  # cascading the answer away with its target.
  defp insert_remote_reply_ref!(%Post{} = post, %Note{} = note) do
    write_remote_reply_ref!(post, %{
      note_id: note.id,
      in_reply_to_uri: note.object_uri,
      actor_uri: note.actor_uri,
      inbox_uri: note.inbox_uri,
      handle: truncate_handle(Note.display_handle(note))
    })
  end

  # The same row for a post by a followed account (issue #1165). Its author is
  # an account row we resolved from a verified actor document, so its inbox has
  # the property the note path relies on: an inbox on the actor's own host.
  defp insert_remote_reply_ref!(%Post{} = post, %RemotePost{} = remote_post) do
    account = remote_post.remote_account

    write_remote_reply_ref!(post, %{
      remote_post_id: remote_post.id,
      in_reply_to_uri: remote_post.object_uri,
      actor_uri: account.actor_uri,
      inbox_uri: account.inbox_uri,
      handle: truncate_handle(RemoteAccount.display_handle(account))
    })
  end

  # The handle is cosmetic and composed from two independently 255-capped remote
  # values ("@" <> handle <> "@" <> host), so it can overrun its own column.
  # Cut it rather than lose the whole answer to an over-long display string: the
  # addresses delivery actually uses are stored separately and untouched.
  defp truncate_handle(handle) when is_binary(handle), do: String.slice(handle, 0, 255)
  defp truncate_handle(handle), do: handle

  defp write_remote_reply_ref!(%Post{} = post, attrs) do
    %PostRemoteReply{post_id: post.id}
    |> PostRemoteReply.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_reply_ref!(_post, nil), do: :ok

  defp insert_reply_ref!(%Post{} = post, %Post{} = parent) do
    Repo.insert!(%PostReply{
      post_id: post.id,
      parent_post_id: parent.id,
      parent_author_id: parent.user_id,
      root_post_id: thread_root_id(parent)
    })
  end

  # The thread a reply lands in is its parent's thread; answering a top-level
  # post starts the thread at that post. A degraded parent (a reply whose own
  # root was deleted, root_post_id NULL) re-anchors the thread at the parent —
  # the chain above it is gone anyway.
  defp thread_root_id(%Post{} = parent) do
    Repo.one(from(r in PostReply, where: r.post_id == ^parent.id, select: r.root_post_id)) ||
      parent.id
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

  # Sets the hold inside the insert transaction (issue #1104), so the struct
  # the caller gets back already knows the post is not public yet — the
  # composer's own card would otherwise render one state behind.
  defp hold_for_image_check!(%Post{} = post) do
    pending? =
      Repo.exists?(
        from(i in PostImage, where: i.post_id == ^post.id and i.moderation == "pending")
      )

    if pending? do
      Repo.update_all(from(p in Post, where: p.id == ^post.id), set: [images_pending?: true])
      %{post | images_pending?: true}
    else
      post
    end
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
  A post is in the moderation freezer, its photos have not finished the AI
  image scan, or its author's whole account is hidden (frozen pending review,
  suspended, or deactivated). Such posts vanish for everyone but the author
  (first `visible_to?/2` clause) and admins — and unlike a plain audience
  restriction, no teaser stands in for them (a frozen post gets a 404, not a
  "Follow to read" tombstone).

  **The photo case holds the whole post, not just the picture** (issue #1104):
  a post with six photos reaches the feed, the profile and the Fediverse only
  once the scan has passed all six. Publishing the text with the unchecked
  pictures blanked would mean the post is *seen* before it is vetted, which is
  exactly what the scan exists to prevent — and it would hand every reader a
  half-rendered card. The author keeps seeing it, marked as not yet public
  (`VutuvWeb.PostComponents.photo_check_progress/1`).

  The moderation policy lives in Vutuv.Moderation; render paths usually carry
  the author preloaded, so the user fetch is the fallback, not the rule.
  """
  def moderation_hidden?(%Post{} = post) do
    post.frozen_at != nil or post.images_pending? == true or author_hidden?(post)
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

  # The moderation arm of scope_visible/2: frozen posts, posts still waiting
  # for the AI image scan (issue #1104), and posts whose author's account is
  # hidden (frozen / suspended / deactivated) vanish from every list, except
  # the author's own. The SQL twin of moderation_hidden?/1; the hidden-account
  # condition itself is owned by Vutuv.Moderation.Query.
  defp scope_unfrozen(query, viewer) do
    passes =
      dynamic(
        [p],
        is_nil(p.frozen_at) and p.images_pending? == false and not account_hidden(p.user_id)
      )

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
  A member cannot like their **own** post (`{:error, :self}`): a self-vote
  inflating your own like count is not a real endorsement (issue #1030).
  Bookmarking your own post stays fine — that is a private save.
  """
  def like_post(%User{} = user, %Post{} = post) do
    cond do
      author?(post, user) -> {:error, :self}
      blocked?(user, post) -> {:error, :blocked}
      true -> do_like_post(user, post)
    end
  end

  defp do_like_post(%User{} = user, %Post{} = post) do
    case engage(PostLike, :like, user, post) do
      {:ok, %PostLike{}} ->
        # A fresh like is news for the author; the idempotent repeat is not.
        # Self-likes never reach here (`like_post/2` rejects them upstream).
        Vutuv.Activity.notify_like(post.user_id, user, post.id)
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
          {:ok, %PostRepost{} = repost} ->
            Vutuv.Fediverse.federate_repost(post, user)
            broadcast_new_repost(repost)

          {:ok, :noop} ->
            :ok

          {:error, _} = error ->
            error
        end
    end
  end

  @doc "Removes `user`'s repost (idempotent). The last one lifts the audience lock."
  def unrepost_post(%User{} = user, %Post{} = post) do
    # Only federate the Undo when there really was a repost to undo, so an
    # idempotent unrepost of a post the member never boosted stays silent.
    reposted? =
      Repo.exists?(from(r in PostRepost, where: r.post_id == ^post.id and r.user_id == ^user.id))

    :ok = disengage(PostRepost, :repost, user, post)
    if reposted?, do: Vutuv.Fediverse.federate_unrepost(post, user)
    :ok
  end

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

  @doc "Whether any likes of this post exist (the edit lock, like reposts)."
  def has_likes?(%Post{id: id}), do: has_likes?(id)

  def has_likes?(post_id) when is_binary(post_id) do
    Repo.exists?(from(l in PostLike, where: l.post_id == ^post_id))
  end

  @doc """
  How many minutes after publishing a post stays editable (issue #1023).

  Installation-wide, `:post_edit_window_minutes` in the config (env var
  `POST_EDIT_WINDOW_MINUTES` in production), 30 by default.
  """
  def edit_window_minutes, do: Application.get_env(:vutuv, :post_edit_window_minutes, 30)

  @doc """
  Whether the post is still inside its edit window — the cheap half of
  `editable?/1`: no query, so the post card can gate its "Edit" menu item on it
  without costing the feed a round trip per card. A **frozen** post reopens the
  window: editing is one of the three ways out of the moderation freezer, and
  nobody but the owner can see it meanwhile.
  """
  def edit_window_open?(%Post{frozen_at: frozen_at, inserted_at: inserted_at}) do
    frozen_at != nil or
      NaiveDateTime.diff(NaiveDateTime.utc_now(), inserted_at) < edit_window_minutes() * 60
  end

  @doc """
  Whether the author may still edit this post: inside the edit window and not
  yet liked, reposted or answered by anyone (issue #1023). Costs one query; the
  post card gates on `edit_window_open?/1` instead and lets the edit page
  explain the rest.
  """
  def editable?(%Post{} = post), do: check_edit_open(post) == :ok

  # An edit rewrites what somebody else already put their name to: a like on
  # "I love kittens" reads as a like on "I hate kittens" after the edit, and
  # nobody is told. A repost carries the words onto someone else's timeline, a
  # reply answers them in public — all three leave a person standing behind
  # text they no longer chose. So a post is only editable while it is young and
  # untouched — long enough to fix the typo you spot right after posting.
  # Deleting stays possible, and a frozen post keeps its moderation round.
  defp check_edit_open(%Post{} = post) do
    cond do
      post.frozen_at != nil -> :ok
      not edit_window_open?(post) -> {:error, :edit_window_closed}
      engaged?(post) -> {:error, :edit_engaged}
      true -> :ok
    end
  end

  defp engaged?(%Post{} = post),
    do: has_likes?(post) or has_reposts?(post) or has_replies?(post)

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
      # Liking, bookmarking or reposting a post is proof the member read it, so
      # whatever the notifications feed has to say about that post is old news
      # — including on the idempotent repeat, which is still a member acting on
      # a post in front of them.
      Vutuv.Activity.mark_post_seen(user.id, post.id)

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
          ),
        # What OTHER networks did with this post (issue #1068): favourites and
        # re-shares that arrived over ActivityPub. Counted **per verb**, because
        # a favourite is a like and an `Announce` is a repost — the same two
        # acts the buttons above count, so the card can show one figure each
        # (`shown_counts/1`) and still break it down for whoever asks.
        fediverse_likes:
          fragment(
            "(SELECT count(*) FROM fediverse_reactions fr WHERE fr.post_id = ? AND fr.kind = 'like')",
            unquote(post).id
          ),
        fediverse_reposts:
          fragment(
            "(SELECT count(*) FROM fediverse_reactions fr WHERE fr.post_id = ? AND fr.kind = 'announce')",
            unquote(post).id
          ),
        # ...and WHO they were. A bare number told the author nothing: their
        # post had travelled somewhere and there was no way to see where or to
        # whom (issue #1068 shipped the count alone). Each entry is the stored
        # account address and the verb, which is the whole row — there is
        # nothing else about these people to show.
        #
        # Capped here rather than in the renderer: a post with a thousand boosts
        # must not drag a thousand rows into every feed card, and the count
        # above already carries the true total for the "+N more" tail. Rides the
        # engagement select so it is batched with the counters, reaches the
        # `{:post_counters, …}` broadcast, and needs no second round trip on any
        # page that already loads engagement.
        fediverse_reaction_actors:
          fragment(
            """
            (SELECT coalesce(json_agg(a ORDER BY a.received_at DESC, a.id DESC), '[]'::json)
               FROM (SELECT fr.id, fr.kind, fr.actor_uri, fr.handle, fr.received_at,
                            (SELECT ra.id FROM fediverse_remote_accounts ra
                              WHERE ra.actor_uri = fr.actor_uri) AS account_id
                       FROM fediverse_reactions fr
                      WHERE fr.post_id = ?
                      ORDER BY fr.received_at DESC, fr.id DESC
                      LIMIT 4) a)
            """,
            unquote(post).id
          ),
        # Replies written on other networks (issue #1069), on their own figure
        # for the same reason. **Public ones only**: a reply addressed to the
        # member alone (issue #1071) must not move a number anybody else can
        # read, or the count itself would leak that a private message exists.
        fediverse_replies:
          fragment(
            "(SELECT count(*) FROM fediverse_notes fn WHERE fn.post_id = ? AND fn.audience = 'public')",
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

    Repo.one(query) ||
      %{
        likes: 0,
        bookmarks: 0,
        reposts: 0,
        replies: 0,
        fediverse_likes: 0,
        fediverse_reposts: 0,
        fediverse_reaction_actors: [],
        fediverse_replies: 0
      }
  end

  @doc """
  The three figures a reader sees on the action bar: vutuv's own tally plus
  what other networks did with the same post.

  A favourite from another server is a like, an `Announce` is a repost and a
  public remote reply is a reply, so one post has **one** like count, one reply
  count and one repost count — a member should not have to add two columns in
  their head to learn how their post did (the card used to print the vutuv
  figures in the buttons and the remote ones on a line of their own).

  Nothing is hidden by the folding: `fediverse_likes` / `fediverse_reposts` /
  `fediverse_replies` stay on the engagement map, and the card's expandable
  "from other networks" panel breaks the totals back down, names the accounts
  and says the numbers above already include them. So a reader can still see
  which world answered — and a server that inflates its own figures inflates a
  line that is labelled as theirs.
  """
  def shown_counts(engagement) do
    %{
      likes: engagement.likes + remote_count(engagement, :fediverse_likes),
      reposts: engagement.reposts + remote_count(engagement, :fediverse_reposts),
      replies: engagement.replies + remote_count(engagement, :fediverse_replies)
    }
  end

  @doc "Favourites and re-shares from other networks together (issue #1068)."
  def fediverse_reaction_count(engagement) do
    remote_count(engagement, :fediverse_likes) + remote_count(engagement, :fediverse_reposts)
  end

  # An engagement map assembled by hand (a test, a host that built one before
  # these keys existed) may not carry the remote figures; a missing one means
  # "nothing arrived", never a crash on a post card.
  defp remote_count(engagement, key), do: Map.get(engagement, key) || 0

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

  @doc """
  Re-broadcasts a post's counters to every open action bar. The Fediverse inbox
  calls it when a remote reaction lands or is withdrawn (issue #1068), so the
  "reactions from other networks" line ticks over with no reload.
  """
  def broadcast_post_counters(post_id), do: broadcast_counters(post_id)

  @doc """
  Tells every open page showing this post that one of its photos has finished
  the AI image scan (issue #1104).

  It goes to **two** topics on purpose. The post's own topic reaches the
  permalink, which subscribes per shown post. The **author's** activity topic
  reaches their feed and profile, which subscribe to themselves and not to
  every post they can see — and the author is the one actually waiting, since
  it is their post that is being checked.

  Callers hand in the post id; `Vutuv.Moderation.ImageSubjects` calls it from
  the one place that runs on both the approve and the reject path.
  """
  def broadcast_images_settled(post_id) when is_binary(post_id) do
    # Recompute the hold first, so every listener that re-reads the post sees
    # the state the message announces.
    became_public? = refresh_images_pending(post_id)

    event = {:post_images_settled, %{post_id: post_id, public?: became_public?}}
    Phoenix.PubSub.broadcast(Vutuv.PubSub, post_topic(post_id), event)

    # `Vutuv.Activity.broadcast/2` is the house helper for a member's own
    # topic, and it no-ops on a nil recipient — which is exactly the
    # already-deleted-post case.
    author_id = Repo.one(from(p in Post, where: p.id == ^post_id, select: p.user_id))
    Vutuv.Activity.broadcast(author_id, event)

    # The post only now exists for anybody else, so this is when its followers
    # are told about it — the `{:new_post, …}` fan-out that a held post skipped
    # at creation. Without this a photo post would reach a follower's feed only
    # on their next full reload.
    if became_public? and author_id, do: broadcast_new_post_to_followers(post_id, author_id)

    :ok
  end

  def broadcast_images_settled(_post_id), do: :ok

  @doc """
  Recomputes a post's `images_pending?` hold from its photos, and answers
  whether **this call** is the one that released it (issue #1104).

  The one owner of that column. Called at each of the three moments it can
  change: a post is created, a post is edited (which can attach fresh photos),
  and a scan settles. It is written with a guarded `update_all` so two scans
  finishing at once cannot both claim the release and fan the post out twice.
  """
  def refresh_images_pending(post_id) when is_binary(post_id) do
    {changed?, pending?} = recompute_images_pending(post_id)
    changed? and not pending?
  end

  def refresh_images_pending(_post_id), do: false

  # `{changed?, pending?}` — the write and the resulting state. The write is
  # guarded on the value actually differing, so two scans finishing at the same
  # moment cannot both report the release and fan the post out twice.
  defp recompute_images_pending(post_id) do
    pending? =
      Repo.exists?(
        from(i in PostImage,
          where: i.post_id == ^post_id and i.moderation == "pending"
        )
      )

    {changed, _} =
      Repo.update_all(
        from(p in Post, where: p.id == ^post_id and p.images_pending? != ^pending?),
        set: [images_pending?: pending?]
      )

    {changed == 1, pending?}
  end

  @doc """
  Whether this post is being held back from everyone but its author while the
  AI image scan runs. What the card asks to decide between "not public yet"
  and an ordinary post.
  """
  def held_for_image_check?(%Post{images_pending?: pending}), do: pending == true

  @doc """
  How far the AI image scan has got on this post: `%{total:, checked:,
  pending:}` (issue #1104).

  What the "checking your photos" indicator counts. `total` is the photos
  still on the post — a rejected one is deleted, so the total shrinks rather
  than a photo sitting at "not checked" forever, which is the honest way round:
  the author is told separately that a picture was removed.
  """
  def image_check_progress(%Post{images: images}) when is_list(images) do
    pending = Enum.count(images, &(not ImageScans.released?(&1.moderation)))
    %{total: length(images), checked: length(images) - pending, pending: pending}
  end

  def image_check_progress(_post), do: %{total: 0, checked: 0, pending: 0}

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

  @doc "Posts per page in the tag page's \"Posts with this tag\" section (#946)."
  def tag_posts_per_page, do: @tag_posts_per_page

  @doc """
  How many public posts carry `tag` (the total behind the tag page's post
  pager). Same anonymous-visibility gate as `list_tag_posts/3`.
  """
  def count_tag_posts(%Tag{} = tag) do
    tag |> tag_posts_query() |> Repo.aggregate(:count)
  end

  @doc """
  One page of the public posts carrying `tag`, newest first, for the tag
  page's "Posts with this tag" section (issue #946). Anonymous view: only posts
  every visitor may read surface (`scope_visible(nil)`), same gate as
  `search_public/2`. Matches the exact tag (its id), not a name substring —
  this is "posts filed under this tag", not a search. Preloaded like every
  rendered post.

  Offset-paginated from the `?page` param via `Vutuv.Pages` (like the tag
  index and the member directory), `tag_posts_per_page/0` rows per page. Pass
  `total:` (from `count_tag_posts/1`) to reuse a count the caller already has;
  `per_page:` overrides the page size (tests). Both must match the `<.pager>`.
  """
  def list_tag_posts(%Tag{} = tag, params \\ %{}, opts \\ []) do
    per_page = Keyword.get(opts, :per_page, @tag_posts_per_page)
    total = Keyword.get(opts, :total) || count_tag_posts(tag)

    tag
    |> tag_posts_query()
    |> order_by([p], desc: p.id)
    |> Pages.paginate(params, total, per_page)
    |> Repo.all()
    |> Repo.preload(post_preloads())
  end

  @doc """
  The public posts carrying at least one tag (anonymous view), the `PostTag`
  join exposed as the named binding `:post_tag`. The one visibility gate
  behind both the tag page's posts (`count_tag_posts/1` / `list_tag_posts/3`
  filter it to one tag) and the tag indexability bar
  (`Vutuv.Tags.indexable_tags_query/0` groups it by tag id), so the two can
  never disagree about which posts count.
  """
  def visible_tagged_posts_query do
    from(p in Post,
      join: u in assoc(p, :user),
      join: pt in PostTag,
      as: :post_tag,
      on: pt.post_id == p.id,
      where: u.email_confirmed? == true
    )
    |> scope_visible(nil)
  end

  # The public posts carrying `tag` (unordered, unpaginated), shared by the
  # count and the page query so both apply the exact same visibility gate.
  defp tag_posts_query(%Tag{} = tag) do
    from([post_tag: pt] in visible_tagged_posts_query(), where: pt.tag_id == ^tag.id)
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
        [
          &feed_post_items(viewer, &1, &2),
          &feed_repost_items(viewer, &1, &2),
          &feed_tag_items(viewer, &1, &2),
          &Vutuv.Fediverse.feed_remote_posts(viewer, &1, &2),
          # Fifth: what people the viewer follows *here* have reshared from
          # another network (issue #1166) — the one way a member who follows
          # nobody out there meets that content at all.
          &Vutuv.Fediverse.feed_remote_reposts(viewer, &1, &2),
          # Sixth: what the accounts the viewer follows out there have
          # re-shared (issue #1167) — a large part of what any account
          # contributes, and invisible here until now.
          &Vutuv.Fediverse.feed_remote_boosts(viewer, &1, &2)
        ],
        limit,
        cursor
      )

    %{page | entries: decorate_feed_entries(page.entries, viewer)}
  end

  # Everything the six sources produce, made ready to render.
  #
  # The remote sources (issues #1161, #1166) carry a cached post from another network,
  # which is not a `%Post{}` and has no author here, no thread, no reposters and
  # no engagement. So it is split off, the local pipeline runs on the rest, and
  # the two are merged back through `Vutuv.FeedPage.sort_entries/1` — the same
  # ordering rule the paginator used. The split is what keeps every transform
  # below free of "unless this is a remote entry" branches, and the merge is
  # needed (rather than a guarded map) because `collapse_threads/1` and
  # `collapse_reposts/1` drop and fold entries, so the local half is not 1:1.
  defp decorate_feed_entries(entries, viewer) do
    {remote, local} = Enum.split_with(entries, &remote_feed_entry?/1)

    local =
      local
      |> hydrate_posts()
      |> collapse_threads()
      |> collapse_reposts()
      |> attach_reposters(viewer)

    Vutuv.FeedPage.sort_entries(local ++ decorate_remote(remote, viewer))
  end

  defp decorate_remote([], _viewer), do: []

  defp decorate_remote(remote, viewer) do
    remote |> dedupe_remote() |> attach_remote_images() |> attach_remote_likes(viewer)
  end

  # One card per cached post per page. The same post arrives from two sources
  # when the reader follows its author (issue #1161) *and* somebody who reshared
  # it (issue #1166), or from two people who both reshared it — and there is one
  # cached row behind all of them, so the reader would otherwise see the same
  # words two or three times. The direct entry wins: it carries the author's own
  # publication time, which is the honest stamp, and the reader is following
  # that account precisely to see it first-hand. `collapse_reposts/1` makes the
  # same call for local posts.
  defp dedupe_remote(remote) do
    remote
    # A boost (issue #1167) counts as passed-on too, not as direct: it carries
    # `reposted_by: nil` because the sharer is a remote account rather than a
    # member, and sorting on that alone put every boost *ahead* of the real
    # direct entry — so a reader following an author out there saw their posts
    # relabelled "Reposted by <whoever boosted them>" the moment anybody did.
    |> Enum.sort_by(&(&1[:reposted_by] != nil or &1[:boosted_by] != nil))
    |> Enum.uniq_by(& &1.remote_post.id)
  end

  # Which of the page's remote posts the reader already likes (issue #1164),
  # read once for the whole page. It rides the entry rather than a socket-level
  # set because the feed re-renders a card by re-inserting its entry into the
  # stream, so the state a card draws from has to live on the entry it draws.
  defp attach_remote_likes(remote, viewer) do
    ids = Enum.map(remote, & &1.remote_post.id)
    liked = Vutuv.Fediverse.liked_remote_post_ids(viewer, ids)
    reposted = Vutuv.Fediverse.reposted_remote_post_ids(viewer, ids)

    Enum.map(remote, fn entry ->
      entry
      |> Map.put(:liked?, MapSet.member?(liked, entry.remote_post.id))
      |> Map.put(:reposted?, MapSet.member?(reposted, entry.remote_post.id))
    end)
  end

  # The pictures of the remote half (issue #1163), read once for the whole page
  # rather than once per card. The card is handed only released ones — the read
  # filters on the AI gate — so an entry with no `:images` and one whose
  # pictures are still pending render the same way.
  defp attach_remote_images(remote) do
    by_post = remote |> Enum.map(& &1.remote_post.id) |> Vutuv.Fediverse.list_remote_images()

    Enum.map(remote, &Map.put(&1, :images, Map.get(by_post, &1.remote_post.id, [])))
  end

  @doc """
  Whether a feed entry carries a cached post from another network (issue #1161)
  rather than a vutuv post.

  The **one** test for it, so nothing has to know that such an entry is spotted
  by a present `:remote_post` and an absent `:post`. A renderer picks the card
  from it; every batch read and every scan that reaches for `entry.post` filters
  through it first, because a remote entry has no author, no thread and no
  engagement here.
  """
  def remote_feed_entry?(entry), do: not is_nil(entry[:remote_post])

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

  # Third feed source (issue #872): posts carrying a tag the viewer follows, from
  # authors they do *not* already follow. Following a tag is a subscription to a
  # topic, so it widens the feed with new voices — a followed author's tagged
  # post already arrives via `feed_post_items/3`, so excluding all the viewer's
  # followees here means no cross-source duplication (and `all_followees_of/1`
  # counts muted follows too, so a muted followee's tagged post stays out, just
  # as the mute already keeps it off the direct path). Blocks and the viewer's
  # visibility scope apply exactly as on the other sources; an empty follow set
  # skips the DB entirely.
  defp feed_tag_items(%User{id: viewer_id} = viewer, fetch_n, cursor) do
    case Vutuv.Tags.followed_tag_ids(viewer_id) do
      [] ->
        []

      tag_ids ->
        tag_match =
          from(pt in PostTag,
            where: pt.post_id == parent_as(:post).id and pt.tag_id in ^tag_ids
          )

        from(p in Post,
          as: :post,
          join: u in assoc(p, :user),
          where: p.user_id != ^viewer_id,
          where: p.user_id not in subquery(all_followees_of(viewer_id)),
          where: p.user_id not in subquery(blocked_either_way(viewer_id)),
          where: account_confirmed_row(u),
          where: exists(subquery(tag_match)),
          order_by: [desc: p.inserted_at, desc: p.id],
          limit: ^fetch_n
        )
        |> scope_visible(viewer)
        |> posts_at_or_before(cursor)
        |> Repo.all()
        |> Enum.map(&%{id: "tagpost-#{&1.id}", post: &1, reposted_by: nil, at: &1.inserted_at})
    end
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
        type(^user_id, UUIDv7),
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
    filter = Keyword.get(opts, :type, :all)

    author
    |> author_timeline_query(viewer, filter)
    |> order_by([t], desc: t.at, desc: t.ref_id)
    |> limit(^limit)
    |> Repo.all()
    |> author_entries(author)
    |> collapse_profile_threads()
  end

  # `collapse_threads/1` folds a reply under the post it answers, which only
  # makes sense for entries carrying a vutuv post. A reshared post from another
  # network (issue #1166) has none, so it is set aside and merged back — the
  # same split `decorate_feed_entries/2` makes, for the same reason.
  defp collapse_profile_threads(entries) do
    {remote, local} = Enum.split_with(entries, &remote_feed_entry?/1)

    Vutuv.FeedPage.sort_entries(collapse_threads(local) ++ remote)
  end

  @doc """
  How many timeline entries of `author` `viewer` may see (the "View all"
  label). `filter` (issue #945) scopes the count to one entry kind — see
  `author_timeline_query/3`.
  """
  def count_author_posts(%User{} = author, viewer, filter \\ :all) do
    author |> author_timeline_query(viewer, filter) |> Repo.aggregate(:count)
  end

  @doc """
  `count_author_posts/3` as a tagged `%{kind: "posts_total", total:}` count
  query, for a caller folding it into a wider union — the profile mounts fold
  it into their single per-mount counts query (with the section and social
  count arms) instead of running it as its own round trip.
  """
  def author_timeline_count_query(%User{} = author, viewer, filter \\ :all) do
    from(s in subquery(author_timeline_query(author, viewer, filter)),
      select: %{kind: type(^"posts_total", :string), total: count()}
    )
  end

  @doc """
  The profile card's "Who to follow" candidate pool: the members who posted
  (replies included) within the last `days` days, ranked by the hearts those
  in-window posts collected, post count breaking ties - at most `limit` of
  them, as listing-row `User` structs. A suggestion is a promise that
  following fills your feed, so the pool is built from demonstrated recent
  output and the ranking from what readers actually liked about it; a
  most-followed veteran who went quiet does not qualify. Local hearts only,
  like the discover rail's ranking (fediverse reactions stay out); no
  self-like filter is needed since a member cannot like their own post.
  """
  def top_recent_posters(days, limit) do
    # Re-imported locally: a scoped `import Mod, only:` replaces the module
    # import's visible names inside this function, so both macros must appear.
    import Vutuv.Moderation.Query, only: [account_hidden_row: 1, account_confirmed_row: 1]

    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(), -days, :day)

    stats =
      from(p in Post,
        where: p.inserted_at > ^cutoff,
        left_join: l in PostLike,
        on: l.post_id == p.id,
        group_by: p.user_id,
        select: %{user_id: p.user_id, hearts: count(l.id), posts: count(p.id, :distinct)}
      )

    Repo.all(
      from(u in User,
        join: s in subquery(stats),
        on: s.user_id == u.id,
        where: account_confirmed_row(u) and not account_hidden_row(u),
        order_by: [desc: s.hearts, desc: s.posts, asc: u.first_name, asc: u.id],
        limit: ^limit,
        select: struct(u, ^User.listing_fields())
      )
    )
  end

  @doc """
  Maps a raw filter string (a phx-value or `?type=` query param) to one of the
  timeline filters `author_posts_page/5` / `profile_posts/3` / `count_author_posts/3`
  understand, defaulting to `:all` for anything unrecognised (issue #945).
  """
  def normalize_post_filter(type)
  def normalize_post_filter("posts"), do: :posts
  def normalize_post_filter("reposts"), do: :reposts
  def normalize_post_filter("replies"), do: :replies
  def normalize_post_filter(_type), do: :all

  ## The pinned post (issue #1110)

  @doc """
  Pins `post` to `author`'s profile: the one post their profile shows above
  the timeline, however much they write afterwards.

  **Exactly one post is pinned at a time**, so this *replaces* any earlier
  pin — `users.pinned_post_id` holds a single id, which makes the rule
  structural rather than something the code has to keep true. `post` must be
  the member's own (the caller resolves it owner-scoped); someone else's is
  rejected rather than pinned.

  A federating member's pin also travels: the replaced post (if any) is
  `Remove`d from their ActivityPub `featured` collection and the new one
  `Add`ed, so other networks show the same pin (issue #1110).
  """
  def pin_to_profile(
        %User{id: author_id} = author,
        %Post{id: post_id, user_id: author_id} = post
      ) do
    replaced_id = author.pinned_post_id

    author
    |> Ecto.Changeset.change(pinned_post_id: post_id)
    # Guards the race where the post is deleted between resolving the owner and
    # this write: the FK fails cleanly instead of persisting a dangling pointer.
    |> Ecto.Changeset.foreign_key_constraint(:pinned_post_id)
    |> Repo.update()
    |> case do
      {:ok, user} = ok ->
        # A replacement sends both halves: the old post leaves the collection
        # and the new one joins it. The two name different posts, so the remote
        # end state is the same whichever arrives first (the queue drains
        # concurrently and does not promise an order).
        if replaced_id && replaced_id != post_id do
          Vutuv.Fediverse.federate_unpin(replaced_id, user)
        end

        Vutuv.Fediverse.federate_pin(%{post | user: user}, user)
        ok

      error ->
        error
    end
  end

  def pin_to_profile(%User{}, %Post{}), do: {:error, :not_author}

  @doc """
  Clears `author`'s pinned post, so their profile leads with the newest entry
  again, and `Remove`s it from a federating member's `featured` collection.
  Idempotent — unpinning when nothing is pinned is a no-op update that sends
  nothing.
  """
  def unpin_from_profile(%User{} = author) do
    released_id = author.pinned_post_id

    author
    |> Ecto.Changeset.change(pinned_post_id: nil)
    |> Repo.update()
    |> case do
      {:ok, user} = ok ->
        if released_id, do: Vutuv.Fediverse.federate_unpin(released_id, user)
        ok

      error ->
        error
    end
  end

  @doc """
  `author`'s pinned post as `viewer` may see it, preloaded like every rendered
  post — or `nil` when nothing is pinned or the pin is invisible to this
  viewer (a restricted or frozen post simply does not show up on the profile,
  exactly as it stays out of the timeline). No query when nothing is pinned.
  """
  def pinned_post(%User{pinned_post_id: nil}, _viewer), do: nil

  def pinned_post(%User{pinned_post_id: post_id}, viewer) do
    from(p in Post, where: p.id == ^post_id)
    |> scope_visible(viewer)
    |> Repo.one()
    |> preload_post()
  end

  @doc """
  Whether `post` is the one `user` pinned to their profile — the predicate
  behind the card menu's Pin / Unpin label and the pinned banner.
  """
  def pinned?(%User{pinned_post_id: post_id}, %Post{id: post_id}) when is_binary(post_id),
    do: true

  def pinned?(_user, _post), do: false

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
  # The rail's quality bar: how many members other than the author must have
  # liked a post before it is worth suggesting, and how far back the draw
  # looks for those posts first.
  @discover_min_likes 2
  @discover_window_days 14

  @doc """
  A random handful of well-received public posts for the feed's rail: posts
  in `viewer`'s language that other members liked, from someone other than
  the viewer.

  Suggestions are picked for **reception**, not just recency: a post needs
  likes from at least `#{@discover_min_likes}` members other than its author
  (liking your own post is not a recommendation). Each author contributes one
  post, their best-liked eligible one, and the handful is drawn at random
  from the `@discover_pool` best-liked of those, so the card varies between
  reloads while everything in it cleared the bar.

  The draw walks three tiers and stops as soon as it has a full card, so a
  quiet fortnight or a viewer who already follows everyone active still gets
  a full one:

    1. strangers (nobody `viewer` follows) from the last
       #{@discover_window_days} days — the post-shaped sibling of the "Who to
       follow" suggestions, and the tier that normally fills the card;
    2. strangers of any age — the installation's lasting favourites;
    3. anyone (bar the viewer themselves) from the last
       #{@discover_window_days} days — the fortnight's best posts, even from
       an author `viewer` already follows.

  A *muted* follow is never suggested, in any tier: muting means "keep this
  person's posts away from me". Only when no tier turned up anything at all
  — a brand-new installation where nobody has liked yet, or a language
  nobody has liked in yet — does the rail fall back to the newest eligible
  posts, so it is never permanently empty.

  Language matches on `users.locale` with the empty value counting as
  English, mirroring `VutuvWeb.LiveLocale`'s fallback. Replies (confusing
  without their thread) and image-only posts (nothing to excerpt in a
  compact row) are skipped. Preloaded like every rendered post.
  """
  def discover_posts(%User{} = viewer, opts \\ []) do
    limit = Keyword.get(opts, :limit, @discover_limit)
    window = discover_window_start()

    rows =
      Enum.reduce_while(
        [{:strangers, window}, {:strangers, nil}, {:everyone, window}],
        [],
        fn {audience, since}, rows ->
          drawn = discover_liked_draw(discover_candidates(viewer, audience), since, limit)
          # Tiers overlap, and one author must not fill two rows of the card.
          rows = Enum.uniq_by(rows ++ drawn, & &1.user_id)
          if length(rows) >= limit, do: {:halt, rows}, else: {:cont, rows}
        end
      )

    rows =
      if rows == [],
        do: discover_recent_draw(discover_candidates(viewer, :strangers), limit),
        else: rows

    rows
    |> Enum.take(limit)
    |> Enum.map(& &1.id)
    |> load_discover_posts()
  end

  # Everything the rail requires of a post regardless of how well it did: a
  # same-language member's own readable, publicly visible top-level post,
  # from someone the viewer has neither blocked nor muted. `:strangers`
  # additionally drops everyone the viewer already follows.
  defp discover_candidates(%User{} = viewer, audience) do
    locale = locale_or_english(viewer.locale)

    excluded =
      case audience do
        :strangers -> all_followees_of(viewer.id)
        :everyone -> muted_followees_of(viewer.id)
      end

    from(p in Post,
      as: :post,
      join: u in assoc(p, :user),
      left_join: r in assoc(p, :reply_ref),
      where: is_nil(r.id),
      where: fragment("COALESCE(NULLIF(?, ''), 'en')", u.locale) == ^locale,
      where: p.user_id != ^viewer.id,
      where: p.user_id not in subquery(excluded),
      where: p.user_id not in subquery(blocked_either_way(viewer.id)),
      where: account_confirmed_row(u),
      where: p.body != ""
    )
    |> scope_visible(nil)
  end

  # The like counts the rail ranks on, rolled up once for the whole table
  # (likes are far rarer than posts, so this beats a correlated count per
  # candidate row). No self-like filter is needed: a member cannot like their
  # own post (enforced in `like_post/2`, issue #1030), so every like is by
  # someone other than the author.
  defp discover_like_counts do
    from(l in PostLike,
      join: p in Post,
      on: p.id == l.post_id,
      group_by: l.post_id,
      select: %{post_id: l.post_id, likes: count(l.id)}
    )
  end

  # The main draw: each author's best-liked post that cleared the bar, from
  # `since` onwards (or from all time when `since` is nil).
  defp discover_liked_draw(candidates, since, limit) do
    best_per_author =
      candidates
      |> join(:inner, [post: p], lc in subquery(discover_like_counts()),
        on: lc.post_id == p.id,
        as: :like_count
      )
      |> where([like_count: lc], lc.likes >= @discover_min_likes)
      |> discover_since(since)
      |> distinct([post: p], p.user_id)
      |> order_by([post: p, like_count: lc], asc: p.user_id, desc: lc.likes, desc: p.id)
      |> select([post: p, like_count: lc], %{id: p.id, user_id: p.user_id, likes: lc.likes})

    discover_draw(best_per_author, [desc: :likes, desc: :id], limit)
  end

  # The empty-installation fallback: the old recency draw, one newest post per
  # author. Only reached while nothing at all has been liked.
  defp discover_recent_draw(candidates, limit) do
    newest_per_author =
      candidates
      |> distinct([post: p], p.user_id)
      |> order_by([post: p], asc: p.user_id, desc: p.id)
      |> select([post: p], %{id: p.id, user_id: p.user_id})

    discover_draw(newest_per_author, [desc: :id], limit)
  end

  defp discover_since(query, nil), do: query
  defp discover_since(query, since), do: where(query, [post: p], p.inserted_at >= ^since)

  defp discover_window_start do
    NaiveDateTime.utc_now(:second) |> NaiveDateTime.add(-@discover_window_days, :day)
  end

  # Rank the one-post-per-author set, keep the best `@discover_pool` of them
  # and pick the handful at random, so the card stays varied between reloads.
  defp discover_draw(per_author, pool_order, limit) do
    pool =
      from(s in subquery(per_author),
        order_by: ^pool_order,
        limit: @discover_pool,
        select: %{id: s.id, user_id: s.user_id}
      )

    from(s in subquery(pool),
      order_by: fragment("random()"),
      limit: ^limit,
      select: %{id: s.id, user_id: s.user_id}
    )
    |> Repo.all()
  end

  defp load_discover_posts([]), do: []

  defp load_discover_posts(ids) do
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

  # The people the viewer told us to keep quiet — excluded from every
  # discovery tier, including the one that may otherwise suggest a followee.
  defp muted_followees_of(viewer_id) do
    from(c in Follow, where: c.follower_id == ^viewer_id and c.muted, select: c.followee_id)
  end

  # How many posts a suggested profile previews by default, and the quality bar
  # each one has to clear.
  @posts_per_author 2
  @posts_min_likes 1

  @doc """
  The newest posts of each of `authors`, as `%{author_id => [teaser]}`, newest
  first — what the "Who to follow" rows preview so a member can tell what an
  account actually writes about before following it.

  A teaser is `%{id:, body:, inserted_at:, likes:, image:}`: enough for the
  rail to render each post as a post rather than as a paragraph of grey text —
  when it was written, how it was received (own likes **and** favourites from
  other networks, folded into one figure like `shown_counts/1`) and its lead
  photo (`nil` when there is none, or while the image scan still holds it).

  Scoped to what `viewer` may see (`nil` for a logged-out visitor, who gets the
  anonymous view). Three kinds of post never make it in. **Replies**: two lines
  of an answer to a stranger's post say nothing about the account. **Bodyless
  photo posts**: no excerpt to show. And **anything nobody liked** — the rail
  is asking a member to bet their feed on a stranger, so it shows the posts
  that landed (at least #{@posts_min_likes} like), not merely the last ones
  typed. An author with nothing that clears the bar is simply absent from the
  map, so a caller reads it with `Map.get(map, id, [])` and renders the plain
  row.

  Two queries for the whole card, never one per suggested member: the bar is
  applied *before* a window function ranks what is left (an unliked post must
  not eat one of the `per_author` slots, default #{@posts_per_author}), then
  one pass fetches those posts' photos.
  """
  def recent_posts_by_authors(authors, viewer, opts \\ []) do
    per_author = Keyword.get(opts, :per_author, @posts_per_author)
    min_likes = Keyword.get(opts, :min_likes, @posts_min_likes)
    author_ids = authors |> Enum.map(&author_id/1) |> Enum.uniq()

    if author_ids == [],
      do: %{},
      else: fetch_recent_posts(author_ids, viewer, per_author, min_likes)
  end

  defp author_id(%User{id: id}), do: id
  defp author_id(id) when is_binary(id), do: id

  defp fetch_recent_posts(author_ids, viewer, per_author, min_likes) do
    candidates =
      from(p in Post, as: :post)
      |> join(:left, [post: p], r in assoc(p, :reply_ref), as: :reply_ref)
      |> where([post: p], p.user_id in ^author_ids and p.body != "")
      |> where([reply_ref: r], is_nil(r.id))
      |> scope_visible(viewer)
      |> select([post: p], %{
        id: p.id,
        user_id: p.user_id,
        body: p.body,
        inserted_at: p.inserted_at,
        # One like figure per post, vutuv's own plus the favourites other
        # networks sent (issue #1068) — the same folding `shown_counts/1` does
        # for the card, so the rail can't quote a different number than the
        # post it links to, and the bar below can't mean something else than
        # the heart the reader sees.
        likes:
          fragment(
            """
            (SELECT count(*) FROM post_likes l WHERE l.post_id = ?)
            + (SELECT count(*) FROM fediverse_reactions fr
                 WHERE fr.post_id = ? AND fr.kind = 'like')
            """,
            p.id,
            p.id
          )
      })

    ranked =
      from(c in subquery(candidates),
        where: c.likes >= ^min_likes,
        select: %{
          id: c.id,
          user_id: c.user_id,
          body: c.body,
          inserted_at: c.inserted_at,
          likes: c.likes,
          rank: over(row_number(), partition_by: c.user_id, order_by: [desc: c.id])
        }
      )

    teasers =
      from(r in subquery(ranked),
        where: r.rank <= ^per_author,
        order_by: [asc: r.rank],
        select: %{
          id: r.id,
          user_id: r.user_id,
          body: r.body,
          inserted_at: r.inserted_at,
          likes: r.likes
        }
      )
      |> Repo.all()

    images = teaser_images(Enum.map(teasers, & &1.id))

    teasers
    |> Enum.map(&Map.put(&1, :image, Map.get(images, &1.id)))
    |> Enum.group_by(& &1.user_id)
  end

  # The lead photo of each teased post, as `%{post_id => %PostImage{}}`. Only
  # images the AI scan has released can be shown: the proxy 404s on the rest,
  # so a held photo must leave the rail thumbnail-less rather than broken.
  defp teaser_images([]), do: %{}

  defp teaser_images(post_ids) do
    from(i in PostImage,
      where: i.post_id in ^post_ids,
      order_by: [asc: i.position, asc: i.id]
    )
    |> Repo.all()
    |> Enum.filter(&ImageScans.released?(&1.moderation))
    |> Enum.reduce(%{}, fn image, acc -> Map.put_new(acc, image.post_id, image) end)
  end

  @doc """
  One offset page of `author`'s timeline visible to `viewer` — the author
  archive at `/:slug/posts` (browse-style pagination, like followers/tags).
  An optional `period` (`{from, to}` dates, inclusive) scopes it to the
  year/month/day index pages; reposts date by the repost, not the original
  publication. `filter` (issue #945) narrows it to one entry kind — see
  `author_timeline_query/3`. Returns `{entries, total}` (entry shape as in
  `feed_page/2`).
  """
  def author_posts_page(%User{} = author, viewer, params, period \\ nil, filter \\ :all) do
    query = author |> author_timeline_query(viewer, filter) |> scope_period(period)
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
  # `filter` narrows the timeline to one entry kind (issue #945): `:all` keeps
  # everything (own posts, own replies and reposts), `:posts` only top-level
  # own posts, `:replies` only own replies, `:reposts` only reposts. The
  # reply split keys on whether the post carries a PostReply row (its
  # `has_one :reply_ref`); `:reposts` skips the originals leg entirely.
  defp author_timeline_query(%User{id: author_id}, viewer, filter) do
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
      |> scope_original_kind(filter)

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

    # A third leg (issue #1166): posts from another network this member shared
    # onward. Same five columns as the others so the union holds, with
    # `post_id` naming a cached remote post instead of a vutuv one —
    # `author_entries/2` splits them apart again by `kind`.
    remote_reposts =
      from(r in FediversePostRepost,
        join: rp in RemotePost,
        on: rp.id == r.remote_post_id,
        where: r.user_id == ^author_id,
        # Re-asked rather than trusted: the author can narrow their post after
        # somebody here reshared it, and a timeline is a public page.
        where: rp.audience in ^RemotePost.open_audiences(),
        select: %{
          kind: type(^"remote_repost", :string),
          ref_id: r.id,
          post_id: r.remote_post_id,
          at: r.inserted_at,
          on_date:
            fragment("((? AT TIME ZONE 'UTC') AT TIME ZONE 'Europe/Berlin')::date", r.inserted_at)
        }
      )

    # Everything this member reshared, whichever world it came from: the two
    # legs answer one question and are always wanted together.
    shared = union_all(reposts, ^remote_reposts)

    case filter do
      :posts -> from(t in subquery(originals))
      :replies -> from(t in subquery(originals))
      :reposts -> from(t in subquery(shared))
      _all -> from(t in subquery(union_all(originals, ^shared)))
    end
  end

  # The `:posts` / `:replies` split of the originals leg: `:posts` drops any
  # post that carries a reply row, `:replies` keeps only those. `:all` and
  # `:reposts` leave the leg untouched (the caller unions it in or ignores it).
  defp scope_original_kind(query, :posts) do
    from(p in query, left_join: pr in PostReply, on: pr.post_id == p.id, where: is_nil(pr.id))
  end

  defp scope_original_kind(query, :replies) do
    from(p in query, join: pr in PostReply, on: pr.post_id == p.id)
  end

  defp scope_original_kind(query, _filter), do: query

  defp author_entries(rows, %User{} = author) do
    {remote_rows, local_rows} = Enum.split_with(rows, &(&1.kind == "remote_repost"))
    posts = load_author_posts(local_rows)
    remote_posts = load_remote_reposted(remote_rows)

    rows
    |> Enum.map(&author_entry(&1, author, posts, remote_posts))
    |> Enum.reject(&is_nil/1)
  end

  defp author_entry(%{kind: "remote_repost"} = row, author, _posts, remote_posts) do
    case remote_posts[row.post_id] do
      {remote_post, images} ->
        # The same entry shape the feed's remote sources produce, so one card
        # renders it and nothing here has to know two vocabularies.
        %{
          id: "remote_repost-#{row.ref_id}",
          post: nil,
          remote_post: remote_post,
          images: images,
          reposted_by: author,
          at: row.at
        }

      nil ->
        nil
    end
  end

  defp author_entry(row, author, posts, _remote_posts) do
    if post = posts[row.post_id] do
      %{
        id: "#{row.kind}-#{row.ref_id}",
        post: post,
        reposted_by: if(row.kind == "repost", do: author),
        at: row.at
      }
    end
  end

  # The two halves of a timeline page, each read in one query and keyed by id:
  # the vutuv posts its own/repost rows name, and the cached posts from another
  # network its reshare rows name (issue #1166). Neither runs when its half of
  # the page is empty, which is the common case on both sides.
  defp load_author_posts([]), do: %{}

  defp load_author_posts(rows) do
    from(p in Post, where: p.id in ^row_post_ids(rows))
    |> Repo.all()
    |> Repo.preload(post_preloads())
    |> Map.new(&{&1.id, &1})
  end

  defp load_remote_reposted([]), do: %{}

  defp load_remote_reposted(rows) do
    ids = row_post_ids(rows)
    # With their pictures: a photo-only post from another network is one this
    # feature explicitly supports (issue #1163), and without them a reshared
    # one renders as a blank card on a profile.
    images = Vutuv.Fediverse.list_remote_images(ids)

    from(p in RemotePost, where: p.id in ^ids, preload: [:remote_account])
    |> Repo.all()
    |> Map.new(&{&1.id, {&1, Map.get(images, &1.id, [])}})
  end

  defp row_post_ids(rows), do: rows |> Enum.map(& &1.post_id) |> Enum.uniq()

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
  The whole conversation `post` belongs to, as `viewer` sees it: the thread's
  root plus every visible post of the thread, in reading order (`thread_order/1`
  — the reply tree walked depth-first, so every reply follows the post it
  answers) — what the permalink page renders (issue #1006). Fetched in one
  indexed query over the denormalized `post_replies.root_post_id`.

  Returns `%{posts:, truncated?:}`; `truncated?` says the `:limit` cap
  (default #{@default_conversation_limit}) cut the newest tail. The
  permalinked post, its surviving ancestor chain and its direct replies are
  always unioned back in, so the page never loses its own subject — that
  union is also the degraded floor when a deleted root nilified the thread's
  `root_post_id` links and the conversation can no longer be found by root.
  """
  def list_thread(%Post{} = post, viewer, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_conversation_limit)
    {anchor_id, up} = thread_anchor(post, viewer)

    scoped =
      from(p in Post,
        left_join: r in PostReply,
        on: r.post_id == p.id,
        where: r.root_post_id == ^anchor_id or p.id == ^anchor_id,
        order_by: [asc: p.inserted_at, asc: p.id],
        limit: ^(limit + 1)
      )
      |> scope_visible(viewer)
      |> Repo.all()

    truncated? = length(scoped) > limit

    posts =
      (Enum.take(scoped, limit) ++ up ++ [post] ++ list_replies(post, viewer))
      |> Enum.uniq_by(& &1.id)
      |> Repo.preload(post_preloads())
      |> thread_order()

    %{posts: posts, truncated?: truncated?}
  end

  @doc """
  The shipped conversation-window budgets, for the permalink LiveView
  (`VutuvWeb.PostLive.Thread`): the initial `:ancestors` / `:replies` budgets
  `thread_window/3` defaults to, and the `:ancestor_page` / `:reply_page`
  steps its expanders grow them by.
  """
  def thread_window_defaults do
    %{
      ancestors: @thread_context_ancestors,
      ancestor_page: @thread_ancestor_page,
      replies: @thread_reply_page,
      reply_page: @thread_reply_page,
      all_limit: @thread_all_limit
    }
  end

  @doc """
  The conversation `post` belongs to, as a **window around the post** — what
  the permalink page renders since the whole-thread rendering (issue #1006)
  stopped scaling: a long conversation rendered hundreds of cards (and one
  embedded action-bar LiveView each), most of them far from the post the
  visitor came for.

  A conversation loads whole — `%{mode: :all, posts:, total:}` in
  `list_thread/3` reading order, exactly the old page — while it stays both
  **small** (at most `:all_limit` visible posts, #{@thread_all_limit}) and
  **shallow** (the post has at most `:ancestors` ancestors,
  #{@thread_context_ancestors}). Fail either and it returns `%{mode: :window}`
  with the post's surroundings, each part budget-capped and grown on demand by
  the LiveView's expanders.

  The depth half is issue #1156: size alone let a permalink four levels down
  render its whole tree, so the card on top was the conversation's root — by
  then often a topic the exchange had long since drifted away from — and the
  sibling branches nobody had asked for came before the post the visitor had
  followed the link for. Past the ancestor budget the chain *is* the context,
  so it becomes the page and the branches move behind the "read it from the
  start" link. Below the budget the window would show every ancestor anyway,
  and the whole tree is the friendlier read.

  The window's parts:

    * `root` — the conversation's first post, always pinned on top (`nil` when
      the permalinked post is the root itself);
    * `gap` — how many ancestors between the root and `chain` are elided
      (0 = the chain connects to the root; a gap of exactly one is shown
      instead of a one-post expander);
    * `chain` — the `:ancestors` (#{@thread_context_ancestors}) nearest
      ancestors, oldest first, directly above the post;
    * `subtree` — the post itself plus the first `:replies`
      (#{@thread_reply_page}) posts of its own reply subtree, reading order;
    * `more` — how many of the post's subtree posts are still unloaded;
    * `rest` — how many visible posts of the conversation live outside the
      ancestor chain and the post's subtree (sibling branches), reachable via
      the root's own permalink;
    * `total` / `truncated?` — the conversation's visible size, `truncated?`
      when even the id-only skeleton hit its #{@thread_skeleton_limit} cap.

  The window is computed on an id-only skeleton of the conversation (one
  indexed query over `post_replies.root_post_id`), so only the posts actually
  shown are loaded and preloaded. Every shown reply's parent is on the page:
  the subtree chunk is a reading-order prefix, and a parent always precedes
  its replies in it. A degraded conversation (deleted root nilified the
  `root_post_id` links) windows over the same floor `list_thread/3` falls back
  to: the surviving ancestor chain plus the post's direct replies.
  """
  def thread_window(%Post{} = post, viewer, opts \\ []) do
    all_limit = Keyword.get(opts, :all_limit, @thread_all_limit)
    ancestor_budget = Keyword.get(opts, :ancestors, @thread_context_ancestors)
    reply_budget = Keyword.get(opts, :replies, @thread_reply_page)
    skeleton_limit = Keyword.get(opts, :skeleton_limit, @thread_skeleton_limit)

    {skeletons, truncated?} = thread_skeletons(post, viewer, skeleton_limit)
    order = skeleton_order(skeletons)
    total = length(order)
    ancestors = skeleton_ancestors(post.id, Map.new(order))

    if total <= all_limit and not truncated? and length(ancestors) <= ancestor_budget do
      posts = load_thread_posts(Enum.map(order, &elem(&1, 0)))
      %{mode: :all, posts: posts, total: total, truncated?: false}
    else
      thread_window_slices(
        post,
        order,
        ancestors,
        total,
        truncated?,
        ancestor_budget,
        reply_budget
      )
    end
  end

  defp thread_window_slices(
         post,
         order,
         ancestors,
         total,
         truncated?,
         ancestor_budget,
         reply_budget
       ) do
    subtree_ids = focus_subtree(post.id, order)
    {shown_subtree, more} = chunk_prefix(subtree_ids, 1 + reply_budget)
    {root_id, chain_ids, gap} = split_ancestors(ancestors, ancestor_budget)

    posts = load_thread_posts(List.wrap(root_id) ++ chain_ids ++ shown_subtree)
    by_id = Map.new(posts, &{&1.id, &1})

    %{
      mode: :window,
      root: root_id && by_id[root_id],
      gap: gap,
      chain: for(id <- chain_ids, p = by_id[id], do: p),
      subtree: for(id <- shown_subtree, p = by_id[id], do: p),
      more: more,
      rest: total - length(ancestors) - length(subtree_ids),
      total: total,
      truncated?: truncated?
    }
  end

  # The conversation as light `{id, parent_id}` rows, visibility-scoped, in
  # `{inserted_at, id}` order (so a parent always precedes its replies and
  # sibling groups keep their age order without re-sorting). Second element:
  # whether the skeleton cap cut the newest tail.
  defp thread_skeletons(%Post{} = post, viewer, limit) do
    reply_row =
      Repo.one(
        from(r in PostReply,
          where: r.post_id == ^post.id,
          select: {r.root_post_id, r.parent_post_id}
        )
      )

    case reply_row do
      {nil, _parent_id} ->
        # Degraded thread (issue #1006's floor): the deleted root nilified the
        # links, so the conversation is the surviving chain + direct replies.
        degraded_skeletons(post, viewer)

      _ ->
        anchor_id =
          case reply_row do
            nil -> post.id
            {root_id, _} -> root_id
          end

        rows =
          from(p in Post,
            left_join: r in PostReply,
            on: r.post_id == p.id,
            where: r.root_post_id == ^anchor_id or p.id == ^anchor_id,
            order_by: [asc: p.inserted_at, asc: p.id],
            limit: ^(limit + 1),
            select: {p.id, r.parent_post_id}
          )
          |> scope_visible(viewer)
          |> Repo.all()

        truncated? = length(rows) > limit
        rows = if truncated?, do: Enum.take(rows, limit), else: rows

        # The permalinked post itself must always be in its own window, like
        # list_thread/3's union floor — even when the cap cut its tail.
        rows =
          if Enum.any?(rows, &(elem(&1, 0) == post.id)) do
            rows
          else
            rows ++ [{post.id, reply_row && elem(reply_row, 1)}]
          end

        {rows, truncated?}
    end
  end

  defp degraded_skeletons(post, viewer) do
    {_topmost, up} = surviving_chain(post, viewer)

    floor =
      (up ++ [post] ++ list_replies(post, viewer))
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(&{NaiveDateTime.to_erl(&1.inserted_at), &1.id})

    ids = Enum.map(floor, & &1.id)

    parents =
      from(r in PostReply, where: r.post_id in ^ids, select: {r.post_id, r.parent_post_id})
      |> Repo.all()
      |> Map.new()

    {Enum.map(floor, fn p -> {p.id, parents[p.id]} end), false}
  end

  # The skeleton rows in reading order: the same depth-first walk as
  # `thread_forest/1`, on `{id, parent_id}` rows. A row whose parent is not in
  # the set (top-level, or the parent is invisible) is a forest root.
  defp skeleton_order(rows) do
    present = MapSet.new(rows, &elem(&1, 0))

    {roots, answers} =
      Enum.split_with(rows, fn {_id, parent} ->
        is_nil(parent) or not MapSet.member?(present, parent)
      end)

    by_parent = Enum.group_by(answers, &elem(&1, 1))

    Enum.flat_map(roots, &skeleton_walk(&1, by_parent))
  end

  defp skeleton_walk({id, _parent} = row, by_parent) do
    [row | by_parent |> Map.get(id, []) |> Enum.flat_map(&skeleton_walk(&1, by_parent))]
  end

  # The focus's visible ancestors as `[root, ..., parent]`, walked up the
  # skeleton's parent pointers. The walk stops at the first invisible parent,
  # so the window anchors at the oldest still-connected ancestor.
  defp skeleton_ancestors(id, parent_of) do
    case Map.get(parent_of, id) do
      nil ->
        []

      parent ->
        if Map.has_key?(parent_of, parent) do
          skeleton_ancestors(parent, parent_of) ++ [parent]
        else
          []
        end
    end
  end

  # The focus plus its whole subtree, reading order — ids only.
  defp focus_subtree(focus_id, order) do
    by_parent =
      order
      |> Enum.reject(fn {_id, parent} -> is_nil(parent) end)
      |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))

    collect_subtree(focus_id, by_parent)
  end

  defp collect_subtree(id, by_parent) do
    [id | by_parent |> Map.get(id, []) |> Enum.flat_map(&collect_subtree(&1, by_parent))]
  end

  # The first `keep` ids and how many were left out — folding a leftover of
  # exactly one in (a one-post "show more" button would be silly).
  defp chunk_prefix(ids, keep) do
    case length(ids) - keep do
      more when more <= 1 -> {ids, 0}
      more -> {Enum.take(ids, keep), more}
    end
  end

  # Root pinned + the `budget` nearest ancestors; the elided middle is the
  # gap. A gap of one folds in, same reasoning as `chunk_prefix/2`.
  defp split_ancestors([], _budget), do: {nil, [], 0}

  defp split_ancestors([root | rest], budget) do
    case length(rest) - budget do
      gap when gap <= 1 -> {root, rest, 0}
      gap -> {root, Enum.drop(rest, gap), gap}
    end
  end

  # `ids` as fully preloaded posts, keeping `ids` order.
  defp load_thread_posts(ids) do
    posts =
      from(p in Post, where: p.id in ^ids)
      |> Repo.all()
      |> Repo.preload(post_preloads())
      |> Map.new(&{&1.id, &1})

    for id <- ids, post = posts[id], do: post
  end

  @doc """
  The reply tree `entries` really form: a forest of those same maps (anything
  carrying a `:post`), each gaining a `:children` list of the entries that
  answer it. Roots — a top-level post, or a reply whose parent is not among the
  entries — and siblings come oldest first, so a walk reads as the conversation
  happened.

  A thread **branches**: one post can be answered many times, and an answer
  written hours later is not an answer to whatever was posted last. Rendering
  the conversation as a flat chronological list therefore put replies under
  strangers' posts (issue #1027). The permalink page and the feed both nest
  from this, so a reply always sits under its own parent.
  """
  def thread_forest(entries) do
    present = MapSet.new(entries, & &1.post.id)

    {roots, answers} =
      entries
      |> Enum.sort_by(&{NaiveDateTime.to_erl(&1.post.inserted_at), &1.post.id})
      |> Enum.split_with(fn %{post: post} ->
        parent_id = preloaded_parent_id(post)
        is_nil(parent_id) or not MapSet.member?(present, parent_id)
      end)

    by_parent = Enum.group_by(answers, &preloaded_parent_id(&1.post))

    Enum.map(roots, &subtree(&1, by_parent))
  end

  # A reply is always newer than the post it answers, so the parent links form
  # a forest and can never cycle — the walk terminates.
  defp subtree(entry, by_parent) do
    children = by_parent |> Map.get(entry.post.id, []) |> Enum.map(&subtree(&1, by_parent))
    Map.put(entry, :children, children)
  end

  @doc """
  `posts` in reading order: `thread_forest/1` walked depth-first, so every
  reply directly follows the post it answers and a branch's answers stay
  together instead of being interleaved by the clock.
  """
  def thread_order(posts) do
    posts |> Enum.map(&%{post: &1}) |> thread_forest() |> flatten_forest()
  end

  defp flatten_forest(nodes), do: Enum.flat_map(nodes, &[&1.post | flatten_forest(&1.children)])

  # The id of the post a reply answers, straight off the preloaded `reply_ref`
  # (an un-preloaded one is a truthy %NotLoaded{}, hence the struct match) —
  # no query, unlike its `reply_parent_id/1` namesake further down.
  defp preloaded_parent_id(%Post{reply_ref: %PostReply{parent_post_id: id}}), do: id
  defp preloaded_parent_id(_post), do: nil

  # Where the conversation is anchored: the denormalized root for a normal
  # reply, the post itself for a top-level post. A degraded reply (root
  # deleted, `root_post_id` NULL) anchors at its topmost surviving ancestor
  # instead and carries that visible chain along, since the nilified links can
  # no longer reach it by root.
  defp thread_anchor(%Post{} = post, viewer) do
    case Repo.one(
           from(r in PostReply, where: r.post_id == ^post.id, select: {r.id, r.root_post_id})
         ) do
      nil -> {post.id, []}
      {_, root_id} when is_binary(root_id) -> {root_id, []}
      {_, nil} -> surviving_chain(post, viewer)
    end
  end

  # Walks parent links up as far as posts still exist, collecting the ones
  # `viewer` may see. Parents are strictly older posts, so the walk cannot
  # cycle. Returns `{topmost_id, chain}` with the chain oldest first.
  defp surviving_chain(%Post{} = post, viewer, chain \\ []) do
    parent_id =
      Repo.one(from(r in PostReply, where: r.post_id == ^post.id, select: r.parent_post_id))

    case parent_id && Repo.one(from(p in Post, where: p.id == ^parent_id)) do
      nil ->
        {post.id, chain}

      %Post{} = parent ->
        chain = if visible_to?(parent, viewer), do: [parent | chain], else: chain
        surviving_chain(parent, viewer, chain)
    end
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

  @doc """
  A review by id with its post (+ author) preloaded, or `nil` — the cover
  proxy's lookup (`VutuvWeb.ReviewCoverController`).
  """
  def get_review(id) do
    UUIDv7.with_cast(id, fn uuid ->
      PostReview |> Repo.get(uuid) |> Repo.preload(post: [:user])
    end)
  end

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
      # The book/film review sidecar (nil for ordinary posts) — the card
      # renders it wherever the post renders, so it always travels along.
      :review,
      # Present only on an answer to something from another network. The
      # conversation renderer reads it to hang an answer to a *reply* (issue
      # #1070) under the remote card it answers rather than beside it; an answer
      # to a followed account's *post* (issue #1165) has no card above it and
      # instead wears a "Replying to @user@host" line, whose link needs the
      # account behind the post. Two extra batched queries per page, and only
      # for the handful of posts that carry the sidecar at all.
      remote_reply_ref: [remote_post: :remote_account],
      denials: [:denied_user],
      tags: from(t in Tag, order_by: t.name),
      reply_ref: [
        :parent_author,
        parent_post: [
          :user,
          :images,
          :screenshot,
          :review,
          tags: from(t in Tag, order_by: t.name)
        ]
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
  The author's still-pending composer images among `ids`, in the order given.

  This is the recovery half of the eager-upload design: a reconnect re-mounts
  the composer and its socket state dies, but the pending rows survive in the
  DB, and LiveView form recovery replays their ids from the old DOM's hidden
  inputs. Attached rows and other people's rows are silently dropped, so a
  stale or tampered id list can neither steal a photo nor resurrect a removed
  one (removed pending rows are deleted on the spot).
  """
  def pending_images(%User{} = author, ids) when is_list(ids) do
    case parse_ids(ids) do
      [] ->
        []

      parsed ->
        rows =
          Repo.all(
            from(i in PostImage,
              where: i.id in ^parsed and i.user_id == ^author.id and is_nil(i.post_id)
            )
          )

        by_id = Map.new(rows, &{&1.id, &1})
        Enum.flat_map(parsed, &List.wrap(by_id[&1]))
    end
  end

  @doc """
  Writes the composer's per-photo panel (issue #1104): alt text, caption and
  the two opt-ins (`show_camera_info`, `download_original` +
  `download_exact`).

  The **cleanable** guard is the fail-closed half of the download promise: on
  a format `Vutuv.Uploads.MetadataStrip` cannot take apart, "cleaned copy"
  cannot be honoured, so the choice is forced to the exact file — which the
  composer says out loud rather than quietly serving an uncleaned file under
  the cleaned label.
  """
  def update_image_settings(%PostImage{} = image, params) do
    image
    |> PostImage.settings_changeset(params)
    |> force_exact_when_uncleanable(image)
    |> block_exact_when_cropped(image)
    |> Repo.update()
  end

  defp force_exact_when_uncleanable(changeset, image) do
    offering_download? = Ecto.Changeset.get_field(changeset, :download_original)
    wants_cleaned? = not Ecto.Changeset.get_field(changeset, :download_exact)

    if offering_download? and wants_cleaned? and not PostImageStore.cleanable?(image) do
      Ecto.Changeset.put_change(changeset, :download_exact, true)
    else
      changeset
    end
  end

  # The mirror-image guard, and the stronger one (it runs last): once a crop
  # exists, the upload shows what the author cut away, so "the file exactly as
  # I uploaded it" is off the table however the settings arrive. The download
  # route fails closed the same way — this just keeps the stored row honest.
  defp block_exact_when_cropped(changeset, image) do
    if PostImage.cropped?(image) do
      Ecto.Changeset.put_change(changeset, :download_exact, false)
    else
      changeset
    end
  end

  @doc """
  Applies the author's ratio crop to a photo — or removes it (`nil` /
  full-frame) — re-deriving every served version from the kept original
  (`Vutuv.PostImageStore.apply_crop/2`) and persisting the fractions so the
  Regenerator re-applies them. `width`/`height` become the served (cropped)
  dimensions, which is what the mosaic and the `<img>` attributes describe.

  The exact-file download drops with the crop: the upload still shows what
  the author just cut out of the frame, so it must no longer leave the
  server (the composer's copy says so too).
  """
  def crop_image(%PostImage{} = image, crop_param) do
    crop = Crop.normalize(crop_param)

    case PostImageStore.apply_crop(image, crop) do
      {:ok, dimensions} ->
        image
        |> Ecto.Changeset.change(Map.put(dimensions, :crop, crop))
        |> drop_exact_for_crop(crop)
        |> Repo.update()

      {:error, _reason} = error ->
        error
    end
  end

  defp drop_exact_for_crop(changeset, nil), do: changeset

  defp drop_exact_for_crop(changeset, _crop),
    do: Ecto.Changeset.put_change(changeset, :download_exact, false)

  @doc """
  The photo license a member's composer should pre-select: their last pick,
  or the shipped default when they have never made one.
  """
  def default_license(%User{default_post_license: license}),
    do: PhotoLicense.cast(license)

  def default_license(_no_user), do: PhotoLicense.default()

  # Remembers a photo post's license as the author's next pre-selection.
  # Only photo posts count — a text-only post carries the default license
  # nobody chose, and letting that overwrite a photographer's standing pick
  # would silently reset it every time they wrote a sentence.
  defp remember_license(%User{} = author, %Post{license: license} = post) do
    if post.images != [] and PhotoLicense.valid?(license) and
         author.default_post_license != license do
      Repo.update_all(
        from(u in User, where: u.id == ^author.id),
        set: [default_post_license: license]
      )
    end

    :ok
  end

  defp remember_license(_author, _post), do: :ok

  @doc """
  Only the AI-released images of a post — what every anonymous/public
  rendering (agent docs, JSON-LD, OpenGraph, the API) may show. The owner's
  in-limbo view is the post card's business (`VutuvWeb.PostComponents`).
  """
  def released_images(%Post{images: images}), do: released_images(images)

  def released_images(images) when is_list(images),
    do: Enum.filter(images, &ImageScans.released?(&1.moderation))

  def released_images(_not_loaded), do: []

  @doc """
  Whether any picture on this post is still waiting for the AI image scan.

  What federation asks before it sends a post to other networks (issue #1070): a
  Note built while an image is in limbo carries no attachment for it, and nothing
  would ever re-send it, so the picture would simply be missing over there. The
  answer covers both kinds of picture a post can carry — its attached images and
  a book review's fetched cover.

  Takes an id (a fresh read, which is what the scan-settled hook needs) or a post
  whose `:images` and `:review` are already loaded.
  """
  def awaiting_image_release?(post_id) when is_binary(post_id) do
    case UUIDv7.with_cast(post_id, &Repo.get(Post, &1)) do
      nil -> false
      post -> post |> Repo.preload([:images, :review]) |> awaiting_image_release?()
    end
  end

  def awaiting_image_release?(%Post{} = post) do
    pending_images?(post.images) or pending_cover?(post.review)
  end

  defp pending_images?(images) when is_list(images),
    do: Enum.any?(images, &(not ImageScans.released?(&1.moderation)))

  defp pending_images?(_not_loaded), do: false

  # A cover that was fetched but not yet judged. A review with no cover at all,
  # or one whose fetch failed, is not something to wait for.
  defp pending_cover?(%PostReview{cover_status: "ready", cover: cover} = review)
       when is_binary(cover),
       do: not ImageScans.released?(review.cover_moderation)

  defp pending_cover?(_review), do: false

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

  A photo a **draft** still names is not abandoned, however long it has been
  sitting there: the composer will hand it back the moment the member reopens
  it (issue #1148), and sweeping it would restore a draft with holes in it.
  Those images go when their draft does, either on save or through
  `sweep_drafts/1`.
  """
  def sweep_pending_images(max_age_hours \\ @pending_max_age_hours) do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -max_age_hours * 3600)

    from(i in PostImage,
      as: :image,
      where: is_nil(i.post_id) and i.inserted_at < ^cutoff,
      where: not exists(drafts_naming_image())
    )
    |> Repo.all()
    |> Enum.count(&delete_if_pending/1)
  end

  # Correlated "some draft still lists this image". Both `?`s in the fragment
  # are real parameter markers (the outer image's id, the draft's id array),
  # not literal question marks, so nothing shifts.
  defp drafts_naming_image do
    from(d in PostDraft,
      where: fragment("? = ANY(?)", parent_as(:image).id, d.image_ids),
      select: 1
    )
  end

  ## Composer drafts (issue #1148)

  # How long an untouched draft is kept. Long enough that "I'll finish this
  # tomorrow" works and that a holiday does not eat it, short enough that the
  # composer does not greet someone with a half-sentence they have long
  # forgotten writing. Per installation: POST_DRAFT_RETENTION_DAYS.
  @default_draft_max_age_days 30

  @doc "How many days an untouched draft is kept."
  def draft_max_age_days,
    do: Application.get_env(:vutuv, :post_draft_retention_days, @default_draft_max_age_days)

  @doc """
  The member's draft for one composer context, or `nil`.

  `context` is what the composer is: `nil` for the feed's new post, a `%Post{}`
  it is answering, a `%Note{}` (a reply from another network) it is answering,
  or a `%RemotePost{}` (a post by an account the member follows there, issue
  #1165). A draft holding nothing is treated as no draft, so an autosave
  that raced the member emptying the composer cannot make an empty composer
  announce itself as restored.
  """
  def get_draft(%User{} = author, context \\ nil) do
    case Repo.one(from(d in PostDraft, where: ^draft_scope(author, context))) do
      %PostDraft{} = draft -> if PostDraft.any_content?(draft), do: draft, else: nil
      nil -> nil
    end
  end

  @doc """
  Writes the composer's current content for one context, replacing whatever was
  there. Returns `:ok` either way.

  This is an **autosave**, so it never reports a problem to the member: an
  invalid changeset (a body past the post limit, say — which the post itself
  would refuse too) simply skips this round rather than interrupting someone
  mid-sentence. A draft with nothing in it is deleted instead of stored, so
  clearing the composer really clears it.
  """
  def save_draft(%User{} = author, context, attrs) do
    changeset =
      %PostDraft{user_id: author.id}
      |> struct(draft_context_fields(context))
      |> PostDraft.changeset(attrs)

    cond do
      not changeset.valid? ->
        :ok

      not PostDraft.any_content?(Ecto.Changeset.apply_changes(changeset)) ->
        delete_draft(author, context)

      true ->
        changeset
        |> Repo.insert(
          on_conflict:
            {:replace,
             [:body, :tags, :license, :image_ids, :photos, :layout, :fill?, :updated_at]},
          conflict_target: draft_conflict_target(context)
        )
        |> case do
          {:ok, _draft} -> :ok
          {:error, _changeset} -> :ok
        end
    end
  end

  @doc "Drops the member's draft for one context (the post was sent, or discarded)."
  def delete_draft(%User{} = author, context \\ nil) do
    Repo.delete_all(from(d in PostDraft, where: ^draft_scope(author, context)))
    :ok
  end

  @doc """
  Removes drafts nobody has touched in `max_age_days`. Returns how many went.

  Their pending photos go with them on the next image sweep, which spares only
  images a *live* draft names.
  """
  def sweep_drafts(max_age_days \\ draft_max_age_days()) do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -max_age_days * 86_400)

    {count, _} = Repo.delete_all(from(d in PostDraft, where: d.updated_at < ^cutoff))
    count
  end

  # Each composer context as the one draft column that names it — the single
  # place a new context is added. A draft is keyed by which composer it was
  # typed in, so a context missing from here would silently share the new-post
  # composer's key and overwrite its draft.
  defp draft_key(%Post{id: id}), do: {:parent_id, id}
  defp draft_key(%Note{id: id}), do: {:remote_note_id, id}
  defp draft_key(nil), do: nil

  # Answering a followed account's post (issue #1165) is deliberately NOT a
  # draft context, and adding one is not the small change it looks like. Every
  # context needs its own partial unique index, and a new one also has to be
  # excluded from the new-post composer's index — which means dropping and
  # recreating that index. Deploys here are blue/green, so during the switch
  # the previous release is still writing `ON CONFLICT (user_id) WHERE
  # parent_id IS NULL AND remote_note_id IS NULL`, and Postgres infers an
  # arbiter only when the supplied predicate implies the index's: two conjuncts
  # do not imply three, so every keystroke in the old release's feed composer
  # would raise 42P10. Verified against Postgres, not reasoned about. Making it
  # a draft context is therefore an expand/contract pair of deploys, worth doing
  # on its own and not worth smuggling into this feature.
  defp draft_key(_context), do: nil

  # The feed's new-post composer is the row where every context column is NULL,
  # which is why they are also listed: its scope and its conflict target are
  # "none of these".
  @draft_context_columns [:parent_id, :remote_note_id]

  # Read scope and write key of one context, derived from the same `draft_key/1`
  # so a draft can never be looked up under one and stored under another. Each
  # conflict target names the partial unique index that owns its context
  # (`priv/repo/migrations/*_post_drafts*`): `(user_id, <column>) WHERE <column>
  # IS NOT NULL`, and `(user_id) WHERE <every column> IS NULL` for the new post.
  defp draft_scope(%User{id: author_id}, context) do
    case draft_key(context) do
      {column, id} ->
        dynamic([d], d.user_id == ^author_id and field(d, ^column) == ^id)

      nil ->
        mine = dynamic([d], d.user_id == ^author_id)

        Enum.reduce(@draft_context_columns, mine, fn column, scope ->
          dynamic([d], ^scope and is_nil(field(d, ^column)))
        end)
    end
  end

  defp draft_conflict_target(context) do
    case draft_key(context) do
      {column, _id} ->
        {:unsafe_fragment, "(user_id, #{column}) WHERE #{column} IS NOT NULL"}

      nil ->
        nulls = Enum.map_join(@draft_context_columns, " AND ", &"#{&1} IS NULL")
        {:unsafe_fragment, "(user_id) WHERE #{nulls}"}
    end
  end

  # What a new draft row carries of its context: the one column, or nothing at
  # all for the feed's composer.
  defp draft_context_fields(context) do
    case draft_key(context) do
      {column, id} -> [{column, id}]
      nil -> []
    end
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

  # The composer field shares the tags-page tokenizer: only a comma separates
  # ("Elixir, Ruby on Rails" is two tags), so a multi-word tag needs no
  # quoting. Delegates to the list head below for the dedupe + cap.
  defp parse_tag_values(values) when is_binary(values),
    do: values |> Tags.parse_tag_names() |> parse_tag_values()

  # Tag.normalize_value strips a leading `#` (the hashtag form), so "#Elixir"
  # becomes "Elixir" and dedupes/links against the bare tag; a bare "#" drops.
  # A value the tags themselves refuse drops too — one that is nothing but a
  # web or email address, and one that is only punctuation
  # (`Tag.punctuation_only?/1`, which also covers the blank left by a bare "#").
  # Post tags share the global namespace with profile tags, so the composer must
  # not be the back door. Dropping them silently matches how this function
  # treats every other odd value — the post itself still publishes.
  defp parse_tag_values(values) when is_list(values) do
    values
    |> Enum.map(&Tag.normalize_value/1)
    |> Enum.reject(&(Tag.punctuation_only?(&1) or WebAddress.link_only?(&1)))
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

  # A post held for the AI image scan (issue #1104) goes to its **author
  # alone**: their own feed must still show the card they just posted — with
  # its "only you can see this" banner — while a follower getting a "Show 1
  # new post" pill for a post the feed query then filters out would be a dead
  # end. The followers are told instead at the moment the last photo clears
  # (`broadcast_images_settled/1`).
  defp broadcast_new_post(%Post{images_pending?: true} = post) do
    Vutuv.Activity.broadcast(post.user_id, new_post_event(post.id, post.user_id))
  end

  defp broadcast_new_post(%Post{} = post) do
    broadcast_to_followers(post.user_id, new_post_event(post.id, post.user_id))
  end

  # The release fan-out: followers only. The author already has the card on
  # screen from the held broadcast above, and `{:post_images_settled, …}`
  # refreshes it — sending them a second `{:new_post, …}` would re-prepend a
  # post that has not moved.
  defp broadcast_new_post_to_followers(post_id, author_id) do
    event = new_post_event(post_id, author_id)
    Enum.each(follower_ids(author_id), &Vutuv.Activity.broadcast(&1, event))
  end

  defp new_post_event(post_id, author_id),
    do: {:new_post, %{post_id: post_id, author_id: author_id}}

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
    broadcast_post_followers_event(post_id, :post_screenshot_ready)
  end

  @doc """
  The counterpart to `broadcast_screenshot_ready/1`: the author removed a post's
  auto link screenshot, so open feeds/profiles drop it from the card with no
  reload. Fans out to the same recipients (author topic + followers' feeds).
  """
  def broadcast_screenshot_removed(post_id) when is_binary(post_id) do
    broadcast_post_followers_event(post_id, :post_screenshot_removed)
  end

  @doc """
  A book review's cover finished fetching (and cleared moderation) — open
  feeds/profiles re-render the card. Reuses the screenshot-ready event on
  purpose: both mean "an auto-fetched attachment of this post became ready,
  refresh the card", and every LiveView already handles it.
  """
  def broadcast_review_cover_ready(post_id) when is_binary(post_id) do
    broadcast_post_followers_event(post_id, :post_screenshot_ready)
  end

  # Fan a `{event_name, %{post_id:, author_id:}}` out to the post author's own
  # topic and every follower's feed. A no-op for a post that vanished before the
  # broadcast fired.
  defp broadcast_post_followers_event(post_id, event_name) when is_binary(post_id) do
    case Repo.get(Post, post_id) do
      nil ->
        :ok

      %Post{user_id: author_id} ->
        broadcast_to_followers(author_id, {event_name, %{post_id: post_id, author_id: author_id}})
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

  # A new reply ticks the parent's open action bars, notifies its author
  # (self-replies are not news) and tells the thread's other participants.
  defp broadcast_reply(%Post{} = parent, %Post{} = reply) do
    broadcast_reply_count(parent.id)

    if parent.user_id != reply.user_id do
      Vutuv.Activity.notify_reply(parent.user_id, reply.user, parent.id, reply.id)
    end

    notify_thread_participants(parent, reply)
  end

  # Everyone else who wrote in the thread gets the quieter "replied in a
  # thread you posted in" push (the feed's "thread" kind): the root author
  # and every earlier replier — minus the replier themselves, the directly
  # answered author (notified above) and anyone with a block either way to
  # the replier. Without this, an answer to a *third* participant was
  # invisible to the rest of the thread (no badge, no feed entry).
  defp notify_thread_participants(%Post{} = parent, %Post{} = reply) do
    root_id = reply.reply_ref && reply.reply_ref.root_post_id

    if root_id do
      replier_ids =
        Repo.all(
          from(r in PostReply,
            join: p in Post,
            on: p.id == r.post_id,
            where: r.root_post_id == ^root_id,
            distinct: true,
            select: p.user_id
          )
        )

      root_author_id = Repo.one(from(p in Post, where: p.id == ^root_id, select: p.user_id))

      [root_author_id | replier_ids]
      |> Enum.uniq()
      |> Enum.reject(
        &(is_nil(&1) or &1 == reply.user_id or &1 == parent.user_id or
            Vutuv.Social.blocked_between?(&1, reply.user_id))
      )
      # Honor the reader's opt-out on the write side too (issue #1025): the feed
      # query already suppresses the "thread" kind for anyone who turned it off,
      # so pushing a live badge here would leave them a count with nothing
      # behind it. One query keeps only the members who still want the push.
      |> thread_notifiable_ids()
      |> Enum.each(&Vutuv.Activity.notify_thread_reply(&1, reply.user, root_id, reply.id))
    end

    :ok
  end

  # Of the given member ids, the ones who still want thread pushes (issue
  # #1025). Empty in, empty out — no query for a thread with no other eligible
  # participant.
  defp thread_notifiable_ids([]), do: []

  defp thread_notifiable_ids(ids) do
    Repo.all(from(u in User, where: u.id in ^ids and u.thread_notifications?, select: u.id))
  end

  # Reconcile the `post_mentions` rows behind the feed's "mention" kind against
  # what the body says now, and push the live event to everyone newly named.
  # Runs on create, on reply and on every edit, so adding a name notifies,
  # removing one takes the event away again, and the set is always what the
  # current body says — the body stays the source of truth, this table only the
  # resolved index (see `Vutuv.Mentions`).
  #
  # Two members are deliberately left out here rather than in the feed query:
  # the author (naming yourself is not news) and anyone the post is not visible
  # to, since an audience the author can change belongs to the post and is
  # re-derived by this very function on the edit that changes it. Blocks are
  # the opposite case — they change outside the post — so the feed query filters
  # those, exactly as thread events do; the live push below has to repeat that
  # filter because there is no query in its path.
  defp sync_mentions(%Post{} = post) do
    wanted =
      post.body
      |> Mentions.mentioned_users(post.user_id)
      |> Enum.filter(&visible_to?(post, &1))

    existing = Repo.all(from(m in PostMention, where: m.post_id == ^post.id, select: m.user_id))
    added = Enum.reject(wanted, &(&1.id in existing))

    drop_mentions(post, existing -- Enum.map(wanted, & &1.id))
    insert_mentions(post, added)
    Enum.each(added, &notify_mentioned(post, &1))
    :ok
  end

  defp drop_mentions(_post, []), do: :ok

  defp drop_mentions(%Post{} = post, user_ids) do
    Repo.delete_all(
      from(m in PostMention, where: m.post_id == ^post.id and m.user_id in ^user_ids)
    )

    :ok
  end

  defp insert_mentions(_post, []), do: :ok

  defp insert_mentions(%Post{} = post, users) do
    now = NaiveDateTime.utc_now(:second)

    rows =
      Enum.map(
        users,
        &%{
          id: UUIDv7.generate(),
          post_id: post.id,
          user_id: &1.id,
          inserted_at: now,
          updated_at: now
        }
      )

    # A concurrent save of the same post (a double-submitted edit) must not
    # raise on the unique index; the row is the same fact either way.
    Repo.insert_all(PostMention, rows, on_conflict: :nothing)
    :ok
  end

  defp notify_mentioned(%Post{} = post, %User{} = mentioned) do
    unless Vutuv.Social.blocked_between?(mentioned.id, post.user_id) do
      Vutuv.Activity.notify_mention(mentioned.id, post.user, post.id)
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
  defp parse_id(id), do: UUIDv7.cast_or_nil(id)
end
