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

  import Vutuv.Moderation.Query,
    only: [account_hidden: 1, account_confirmed_row: 1, account_hidden_row: 1]

  import Vutuv.Organizations.Query, only: [organization_public_row: 1]
  import Vutuv.SearchText, only: [contains: 1, normalize_search: 1, name_ilike: 3]

  alias Ecto.Association.NotLoaded
  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.PostRepost, as: FediversePostRepost
  alias Vutuv.Fediverse.Reaction
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Keyset
  alias Vutuv.Mentions
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.Pages
  alias Vutuv.PostImageStore
  alias Vutuv.Posts.PhotoLicense
  alias Vutuv.Posts.PopularPosts
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostBookmark
  alias Vutuv.Posts.PostDenial
  alias Vutuv.Posts.PostDraft
  alias Vutuv.Posts.PostHashtag
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
  alias Vutuv.Posts.TopPosters
  alias Vutuv.Prefs
  alias Vutuv.Profiles.Url
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
  # How many likers the permalink names before the rest fold into the avatar
  # stack's `+N` chip (issue #1233). The same cap the row and the agent-format
  # siblings use, so both name the same people.
  @likers_shown 5

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
      case-insensitive; invalid values are skipped, and more than
      `max_tags_per_post/0` distinct ones fail the changeset on `:tags`
      rather than being dropped, issue #1237)
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
  Publishes a post in `organization`'s name, with `acting_user` recorded as the
  member who pressed publish (issue #1334). Returns `{:error, :forbidden}` when
  they do not hold the organization's `publisher` role.

  An organization post is **public**: it carries no denials. The deny model is
  built on the author's own follower graph and blocks, which an organization has
  no equivalent of yet (that is issue #1336), and a half-applied audience would
  read as a promise the site cannot keep. Publishing under a brand is a public
  act; the way to say something to fewer people is to say it as yourself.
  """
  def create_organization_post(%Organization{} = organization, %User{} = acting_user, attrs) do
    if Organizations.publisher?(organization, acting_user) do
      do_create_organization_post(organization, acting_user, attrs)
    else
      {:error, :forbidden}
    end
  end

  defp do_create_organization_post(organization, acting_user, attrs) do
    image_ids = parse_ids(fetch(attrs, :image_ids) || [])
    seed = %Post{organization_id: organization.id, acting_user_id: acting_user.id}

    with :ok <- check_image_count(image_ids),
         {:ok, changeset} <- build_changeset(seed, attrs, [], image_ids) do
      case insert_post(changeset, image_ids, nil, nil) do
        {:ok, post} ->
          post = preload_post(post)
          broadcast_new_post(post)
          sync_mentions(post)
          # A federating page's post goes out to its remote followers (issue
          # #1334); a no-op for every page that has not opted in, which is all
          # of them until an owner switches it on.
          Vutuv.Fediverse.federate_new_post(post)
          reconcile_screenshot(post)
          ReviewCovers.reconcile(post)
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

  @doc """
  Whether this post is a kind of post that accepts replies at all — the half of
  the reply rule that depends on the post alone, with nobody asking yet.

  Public because the reply **page** must ask it too. That page cannot run the
  whole of `check_reply_allowed/2` (a quiet block has to let the blocked member
  reach the composer and be refused on submit, or the block leaks), so without a
  named predicate it kept its own weaker copy of the rule — and offered a
  composer for a page's post, whose heading then dereferenced the member author
  that a page's post does not have.
  """
  def replyable?(%Post{} = post), do: not organization_post?(post)

  defp check_reply_allowed(%User{} = author, %Post{} = parent) do
    cond do
      # An organization post cannot be answered yet (issue #1334). Everything
      # downstream of a reply is member-shaped — the parent-author notification,
      # the block check between the two authors, the thread's "Replying to
      # @handle" line — and an organization has no inbox to be told about it
      # until issue #1336 gives it a reading side. Refusing outright beats a
      # reply that quietly reaches nobody.
      not replyable?(parent) -> {:error, :restricted}
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
    post = Repo.preload(post, [:denials, :post_tags, :post_hashtags, :images, :review])
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

  @doc """
  The attrs that leave a post's **audience and tags exactly as they are**, for a
  caller that edits only part of a post.

  `update_post/2` replaces both wholesale — `put_assoc/3` on associations
  declared `on_replace: :delete` — so attrs that simply do not name `:denials`
  and `:tags` do not leave them alone, they **clear** them. That is not a
  no-op, it is a silent widening: a post its author had closed to somebody
  becomes public, `run_update/3` then federates the newly public version, and
  nothing errors, because `check_visibility_lock/2` only refuses *narrowing*.
  A Mastodon client edits a body and its photos and has no vocabulary for
  either association, so every edit from a phone went down that path.

  Merge it **under** the caller's own attrs (`Map.merge(unchanged, mine)`), so
  a caller that does name either one still wins.
  """
  def unchanged_audience_attrs(%Post{} = post) do
    post = Repo.preload(post, [:denials, :tags])

    %{
      denials: Enum.map(post.denials, &denial_attrs/1),
      tags: Enum.map(post.tags, & &1.name)
    }
  end

  defp denial_attrs(%PostDenial{denied_user_id: id}) when is_binary(id),
    do: %{denied_user_id: id}

  defp denial_attrs(%PostDenial{wildcard: wildcard}), do: %{wildcard: wildcard}

  defp run_update(changeset, removed, image_ids) do
    case Repo.transaction(fn -> apply_update!(changeset, removed, image_ids) end) do
      {:ok, updated} ->
        # Only after the commit: a rolled-back update must not lose files.
        Enum.each(removed, &PostImageStore.delete(&1.token))
        # A reported post that its owner edits leaves the moderation freezer
        # (the owner's self-service round; see Vutuv.Moderation).
        Vutuv.Moderation.content_edited(updated)
        # An edit can attach a fresh photo (a new wait) or drop the last
        # unchecked one (the end of one), so the flag is recomputed here too.
        # Nothing fans out either way: the post has been public since it was
        # written, only its pictures come and go.
        {_changed?, pending?} = recompute_images_pending(updated.id)
        # preload/2 keeps the struct's own columns, so the fresh flag is put
        # back on by hand — the composer navigates to a card built from this.
        updated = %{preload_post(updated) | images_pending?: pending?}

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
        broadcast_post_deleted(post.id, deletion_recipients(post))
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
    tag_values = attrs |> fetch(:tags) |> parse_tag_values()
    # Over the cap the post does not save at all, so nothing is minted for it
    # either: find-or-create runs only on a set that can be kept.
    tag_ids = if too_many_tags?(tag_values), do: [], else: tag_ids_for(tag_values)

    changeset =
      post_or_struct
      |> Post.changeset(post_params(attrs))
      |> Ecto.Changeset.put_assoc(:denials, Enum.map(denials, &struct(PostDenial, &1)))
      |> Ecto.Changeset.put_assoc(:post_tags, Enum.map(tag_ids, &%PostTag{tag_id: &1}))
      |> put_body_hashtags(tag_ids)
      |> put_review(post_or_struct, fetch(attrs, :review))
      |> require_content(image_ids)
      |> validate_tag_count(tag_values)

    if changeset.valid?, do: {:ok, changeset}, else: {:error, changeset}
  end

  defp too_many_tags?(values), do: length(values) > @max_tags

  # The count is the one odd input `parse_tag_values/1` does NOT quietly fix
  # (issue #1237). Everything else it drops is a value that cannot be a tag at
  # all — punctuation, a bare link, a repeat — and dropping those still
  # publishes the post the member wrote. A sixth tag is different: it is
  # something they typed and meant, so it comes back with a reason instead of
  # vanishing from a post that already went out. Counted after the dedupe, so
  # repeating a tag is never what trips it.
  #
  # Keep the message byte-identical to its extraction anchor in
  # `VutuvWeb.ErrorHelpers` — that is what puts it in `errors.pot` and gets it
  # translated, since gettext cannot see a literal inside `add_error/4`.
  defp validate_tag_count(changeset, values) do
    if too_many_tags?(values) do
      Ecto.Changeset.add_error(
        changeset,
        :tags,
        "Please use at most %{max} tags.",
        max: @max_tags
      )
    else
      changeset
    end
  end

  # The tags the body names as `#hashtags`, filed so `/tags/:slug` lists the
  # post — the reader who follows a `#berlin` link out of a post finds that post
  # on the page it took them to.
  #
  # Re-derived from the body on every save (so an edit that drops a hashtag
  # drops the filing), existing tags only (`Tags.tag_ids_for_hashtags/1` mints
  # nothing — a typo must not leave a tag page behind), and never a tag the
  # composer's field already filed: that one is a chip on the card, and one
  # filing per (post, tag) is all the tag page can use.
  defp put_body_hashtags(changeset, field_tag_ids) do
    hashtag_ids =
      changeset
      |> Ecto.Changeset.get_field(:body)
      |> to_string()
      |> Mentions.hashtags()
      |> Tags.tag_ids_for_hashtags()
      |> Enum.reject(&(&1 in field_tag_ids))

    Ecto.Changeset.put_assoc(
      changeset,
      :post_hashtags,
      Enum.map(hashtag_ids, &%PostHashtag{tag_id: &1})
    )
  end

  # The license key is only put through when the caller sent one, so the API's
  # partial PATCH (and every non-photo save path) leaves a stored license
  # alone instead of resetting it to the default. The bento layout follows the
  # same rule — absent key = untouched; a sent "" clears back to automatic
  # (`GalleryLayout.cast/1` in the changeset maps it to nil).
  # The optional attrs and the changeset field each writes; an absent key
  # leaves the stored value untouched (the API's partial PATCH).
  @optional_post_params [
    license: :license,
    layout: :gallery_layout,
    language: :language,
    fill: :gallery_fill?
  ]

  defp post_params(attrs) do
    Enum.reduce(
      @optional_post_params,
      %{body: to_string(fetch(attrs, :body) || "")},
      fn {key, field}, params ->
        case fetch(attrs, key) do
          nil -> params
          value -> Map.put(params, field, value)
        end
      end
    )
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
          mark_images_pending!(post)

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
  # The uploader is NOT always `post.user_id`: an organization post has no
  # member owner (the CHECK is one column or the other), so its pictures belong
  # to the acting member who uploaded them. Reading `user_id` alone made this
  # `i.user_id == ^nil`, which Ecto refuses outright rather than matching no
  # rows — so attaching a photo to a post written in a page's name raised, i.e.
  # a 500 straight out of the composer, which offers the upload either way.
  defp attach_images!(%Post{} = post, image_ids) do
    now = NaiveDateTime.utc_now(:second)
    uploader_id = post.user_id || post.acting_user_id

    image_ids
    |> Enum.with_index()
    |> Enum.each(fn {id, position} ->
      # Belt and braces for a post that somehow names neither: rolling back
      # beats handing the same nil to the query below.
      if is_nil(uploader_id), do: Repo.rollback(:invalid_images)

      {count, _} =
        Repo.update_all(
          from(i in PostImage,
            where:
              i.id == ^id and i.user_id == ^uploader_id and
                (is_nil(i.post_id) or i.post_id == ^post.id)
          ),
          set: [post_id: post.id, position: position, updated_at: now]
        )

      if count != 1, do: Repo.rollback(:invalid_images)
    end)
  end

  # Sets the flag inside the insert transaction (issue #1104), so the struct the
  # caller gets back already knows a photo of its own is still being checked —
  # the composer's own card would otherwise render one state behind and show the
  # author no progress panel at all.
  defp mark_images_pending!(%Post{} = post) do
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

  ## Authorship

  @doc """
  The post's author **as the world sees it**: the `%User{}` who wrote it, or the
  `%Organization{}` it was published in the name of (issue #1334).

  This is the one decision about which of the two nullable author columns
  speaks, and roughly seventy places ask. Reading `post.user` directly is a bug
  on an organization post: it is `nil` there, and the member who pressed publish
  (`acting_user`) is deliberately **not** the public author — they are the
  internal record of who spoke, kept for moderation, disputes and departures.

  `:user` / `:organization` are normally preloaded (`post_preloads/0` does it);
  when they are not, this loads the one it needs rather than handing back an
  `%Ecto.Association.NotLoaded{}`. That costs a query on the paths that forgot,
  and it is worth it: the alternative shipped twice already, as clauses like
  `def f(%Post{organization: %Organization{}})` written all over the display
  layer. Those read as a *type* check and behave as a *preload* check — hand one
  a bare `%Post{}` from a query and the organization branch quietly does not
  match, so the post is drawn as a member's and the member is `nil`.
  """
  def author(%Post{organization_id: nil, user: %NotLoaded{}, user_id: user_id}),
    do: Repo.get(User, user_id)

  def author(%Post{organization_id: nil} = post), do: post.user

  def author(%Post{organization: %NotLoaded{}, organization_id: organization_id}),
    do: Repo.get(Organization, organization_id)

  def author(%Post{} = post), do: post.organization

  @doc "The author's id, whichever kind of author it is."
  def author_id(%Post{organization_id: nil, user_id: user_id}), do: user_id
  def author_id(%Post{organization_id: organization_id}), do: organization_id

  @doc "Whether this post was published in an organization's name rather than a member's."
  def organization_post?(%Post{organization_id: nil}), do: false
  def organization_post?(%Post{}), do: true

  ## Visibility

  @doc """
  Whether `viewer` (a `%User{}` or `nil`) may act as the post's author — the one
  predicate gating the Edit/Delete affordances wherever a post renders.

  For an organization post that is every current **publisher** of the
  organization, not the member who happened to press publish: the post belongs
  to the organization, so the power to change it has to follow the role and not
  the person, or it would walk out of the door with them. It is asked live
  rather than from the stored `acting_user_id`, so a withdrawn role takes effect
  at once.
  """
  def author?(%Post{organization_id: nil, user_id: author_id}, %User{id: author_id}), do: true

  def author?(%Post{organization_id: id} = post, %User{} = viewer) when is_binary(id),
    do: organization_author?(post, viewer)

  # A page asking about its OWN post (issue #1336): it may edit, delete and
  # revoke what it published, like any author.
  def author?(%Post{organization_id: id}, %Organization{id: id}) when is_binary(id), do: true

  def author?(%Post{}, _viewer), do: false

  @doc """
  Whether `actor` **is** the post's author, as opposed to being entitled to act
  in the author's name.

  These are two questions and a page is where they part. `author?/2` answers the
  second one, which is right for editing, deleting and pinning: the power
  follows the role. The self-vote rule behind `like_post/2` needs the first one,
  and for a while it borrowed `author?/2` as well — so every publisher of every
  page was quietly barred from liking their own page's posts, although the like
  would have been theirs and not the page's, while a colleague without the role
  could press the heart. The button was rendered either way and the refusal was
  swallowed, so it read as a dead control.

  A member's own post and a page's own post are both self-votes; a member and
  the page they publish for are not the same identity.
  """
  def self_vote?(%Post{organization_id: nil, user_id: author_id}, %User{id: author_id})
      when is_binary(author_id),
      do: true

  def self_vote?(%Post{organization_id: id}, %Organization{id: id}) when is_binary(id), do: true

  def self_vote?(%Post{}, _actor), do: false

  # Whether `viewer` may currently speak for the post's organization. Takes the
  # preloaded association when there is one and falls back to a lookup when
  # there is not: several callers hand over a bare `%Post{}` from a query, and a
  # permission answer must not depend on whether somebody remembered a preload.
  defp organization_author?(
         %Post{organization: %Organization{} = organization},
         %User{} = viewer
       ),
       do: Organizations.publisher?(organization, viewer)

  defp organization_author?(%Post{organization_id: id}, %User{} = viewer) when is_binary(id) do
    case Organizations.get_organization(id) do
      nil -> false
      organization -> Organizations.publisher?(organization, viewer)
    end
  end

  defp organization_author?(_post, _viewer), do: false

  @doc """
  Whether `viewer` (a `%User{}` or `nil` for anonymous) may see `post`.

  The single source of truth for post access — the permalink page, the
  image proxy and the live-feed pill all call this. List queries use the
  equivalent `scope_visible/2`.
  """
  def visible_to?(%Post{user_id: author_id}, %User{id: author_id}) when is_binary(author_id),
    do: true

  # A page as the VIEWER (issue #1336). It is not a member: no block applies to
  # it and no denial can name it, so it sees exactly what an anonymous reader
  # sees - deliberately conservative, since a restricted audience is a list of
  # members and a page is not on it. Plus its own posts while moderation holds
  # them, the way an author sees theirs.
  def visible_to?(%Post{organization_id: id}, %Organization{id: id}) when is_binary(id),
    do: true

  def visible_to?(%Post{} = post, %Organization{}),
    do: not moderation_hidden?(post) and not restricted?(post)

  # An organization post carries no denials (see `create_organization_post/3`),
  # so the only thing that can hide it is moderation — and its publishers still
  # see it while it is held, the way a member sees their own frozen post.
  #
  # Matched on the **column**, not on a preloaded `:organization`. Half the
  # callers here hand over a bare `%Post{}` straight from a query (the engage
  # path does), and an association-shaped clause silently does not match those —
  # which dropped them into the member branch and `Repo.get(User, nil)`.
  def visible_to?(%Post{organization_id: id} = post, %User{} = viewer) when is_binary(id),
    do: organization_author?(post, viewer) or not moderation_hidden?(post)

  def visible_to?(%Post{organization_id: id} = post, nil) when is_binary(id),
    do: not moderation_hidden?(post)

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
  A post is in the moderation freezer, or its author's whole account is hidden
  (frozen pending review, suspended, or deactivated). Such posts vanish for
  everyone but the author (first `visible_to?/2` clause) and admins — and
  unlike a plain audience restriction, no teaser stands in for them (a frozen
  post gets a 404, not a "Follow to read" tombstone).

  **The AI image scan is deliberately not on this list.** It gates the
  *picture*, not the post: a post whose photo is still being judged publishes
  at once and renders that photo as a placecard tile saying it is being checked
  (`VutuvWeb.PostComponents`), swapping the real picture in by itself when the
  verdict lands. Holding the whole post back was the first shape of issue #1104
  and it broke the one case that shows why the unit matters: a reply carrying a
  photo raised a "somebody answered you" notification for a post the recipient
  then could not find anywhere. Nothing about the scan's purpose needs the text
  hidden — an unvetted picture is never rendered either way, and every machine
  surface (agent formats, RSS, OG, JSON-LD, the Fediverse Note) is built from
  `released_images/1`, so none of them can carry one. `images_pending?` lives on
  as the author's "your photo is still being checked" flag
  (`held_for_image_check?/1`), never as a visibility gate.

  The moderation policy lives in Vutuv.Moderation; render paths usually carry
  the author preloaded, so the user fetch is the fallback, not the rule.
  """
  def moderation_hidden?(%Post{} = post) do
    post.frozen_at != nil or author_hidden?(post)
  end

  # An organization is not an account and cannot be frozen, suspended or
  # deactivated as one; whether its *page* is hidden is `organization_public_row`
  # and belongs to the queries, not here. Answering false is also what keeps
  # `Repo.get(User, nil)` out of every engagement path.
  defp author_hidden?(%Post{organization_id: id}) when is_binary(id), do: false

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

  # The moderation arm of scope_visible/2: frozen posts and posts whose author's
  # account is hidden (frozen / suspended / deactivated) vanish from every list,
  # except the author's own. The SQL twin of moderation_hidden?/1 — it does not
  # ask about `images_pending?` for the same reason that one does not (the scan
  # gates the picture, not the post); the hidden-account condition itself is
  # owned by Vutuv.Moderation.Query.
  defp scope_unfrozen(query, viewer) do
    passes = dynamic([p], is_nil(p.frozen_at)) |> and_author_shown(query)

    filter =
      case viewer do
        %User{id: viewer_id} -> dynamic([p], p.user_id == ^viewer_id or ^passes)
        nil -> passes
      end

    where(query, ^filter)
  end

  # "…and the author's account is not hidden", in whichever of the two spellings
  # the query can afford.
  #
  # `account_hidden/1` re-fetches the author row by id in a correlated EXISTS,
  # which composes into any query but costs a pass over `users` — Postgres
  # de-correlates it into a hashed subplan and scans the whole table to collect
  # the few hundred hidden ids, once per post query (five times on one /feed).
  # A query that already joins the author has those columns in hand, so it uses
  # the row form instead and reads them; `Vutuv.Moderation.Query` documents the
  # pair, and the two say exactly the same thing about the same row.
  #
  # The named binding is the signal: a post query that joins its author as
  # `as: :author` gets the cheaper gate automatically, one that does not keeps
  # the EXISTS. Nothing here decides *whether* a post is shown — only how the
  # question is put to Postgres — so a caller may add or drop the binding
  # freely.
  defp and_author_shown(passes, query) do
    if has_named_binding?(query, :author) do
      dynamic([author: a], ^passes and not account_hidden_row(a))
    else
      dynamic([p], ^passes and not account_hidden(p.user_id))
    end
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

  "Own" here means `self_vote?/2`, not `author?/2`: on a page's post the author
  is the page, so its publishers are liking somebody else's post, and may.
  """
  def like_post(%User{} = user, %Post{} = post) do
    cond do
      self_vote?(post, user) -> {:error, :self}
      blocked?(user, post) -> {:error, :blocked}
      true -> do_like_post(user, post)
    end
  end

  @doc """
  The same, as a **page** (issue #1336). `acting_user` is the publisher who
  pressed it: recorded, never shown.

  The self-vote rule is about the **author**, so a page cannot like its own
  post — its publishers personally still can, because they are not the author.
  There is no block arm: a block is between two people.
  """
  def like_post(%Organization{} = page, %User{} = acting_user, %Post{} = post) do
    cond do
      not Organizations.publisher?(page, acting_user) -> {:error, :not_allowed}
      self_vote?(post, page) -> {:error, :self}
      true -> do_page_like(page, acting_user, post)
    end
  end

  defp do_page_like(%Organization{} = page, %User{} = acting_user, %Post{} = post) do
    case engage(PostLike, :like, page, post, acting_user) do
      {:ok, %PostLike{}} ->
        Vutuv.Activity.notify_like(post.user_id, page, post.id)
        :ok

      {:ok, :noop} ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  # The right to act in a page's name follows the ROLE, so it is asked live
  # rather than trusted from whatever identity the caller arrived with — a
  # withdrawn publisher stops being able to act at once.
  defp may_act_as(%Organization{} = page, %User{} = user) do
    if Organizations.publisher?(page, user), do: :ok, else: {:error, :not_allowed}
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

  @doc "Removes the actor's like (idempotent)."
  def unlike_post(actor, %Post{} = post), do: disengage(PostLike, :like, actor, post)

  @doc "Bookmarks `post` for `user` (idempotent). Only visible posts."
  def bookmark_post(%User{} = user, %Post{} = post) do
    with {:ok, _} <- engage(PostBookmark, :bookmark, user, post), do: :ok
  end

  @doc """
  The same, as a **page** — a shared reading list for its team (issue #1336).
  Private, so unlike a like it needs no self-vote rule: a page may save its own
  post the way a member may save theirs.
  """
  def bookmark_post(%Organization{} = page, %User{} = acting_user, %Post{} = post) do
    with :ok <- may_act_as(page, acting_user),
         {:ok, _} <- engage(PostBookmark, :bookmark, page, post, acting_user),
         do: :ok
  end

  @doc "Removes the actor's bookmark (idempotent)."
  def unbookmark_post(actor, %Post{} = post),
    do: disengage(PostBookmark, :bookmark, actor, post)

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

  @doc """
  The same, as a **page** (issue #1336) — a company amplifying a member's post
  to its own followers.

  It federates like a member's does when the page has opted in and claimed a
  handle: an `Announce` from the page's own actor to the page's own remote
  followers.
  """
  def repost_post(%Organization{} = page, %User{} = acting_user, %Post{} = post) do
    cond do
      not Organizations.publisher?(page, acting_user) -> {:error, :not_allowed}
      restricted?(post) -> {:error, :restricted}
      true -> do_page_repost(page, acting_user, post)
    end
  end

  defp do_page_repost(%Organization{} = page, %User{} = acting_user, %Post{} = post) do
    case engage(PostRepost, :repost, page, post, acting_user) do
      {:ok, %PostRepost{} = repost} ->
        Vutuv.Fediverse.federate_repost(post, page)
        broadcast_new_repost(repost)

      {:ok, :noop} ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc "Removes the actor's repost (idempotent). The last one lifts the audience lock."
  def unrepost_post(%Organization{} = page, %Post{} = post) do
    # Only federate the Undo when there really was a reshare to undo, so an
    # idempotent unrepost of a post the page never boosted stays silent.
    reposted? =
      Repo.exists?(
        from(r in PostRepost, where: r.post_id == ^post.id and r.organization_id == ^page.id)
      )

    :ok = disengage(PostRepost, :repost, page, post)
    if reposted?, do: Vutuv.Fediverse.federate_unrepost(post, page)
    :ok
  end

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

  # Whether any likes of this post exist (the edit lock, like reposts).
  defp has_likes?(%Post{id: id}), do: has_likes?(id)

  defp has_likes?(post_id) when is_binary(post_id) do
    Repo.exists?(from(l in PostLike, where: l.post_id == ^post_id))
  end

  @doc """
  **Who** liked a post, newest first — the faces the permalink shows under the
  like count (issue #1233), and the names the agent-format siblings list.

  A bare number told the author nothing: the only moment they ever learned who
  liked their post was the notification, so a month later the answer lived in
  an old notification list. Meanwhile a favourite from another network has
  named its account on the same card since issue #1068, which left vutuv's own
  members as the one anonymous half of a post's likes.

  Three rules the query encodes:

  * **Attribution is per member.** A member who turned `like_attribution?` off
    (settings → Visibility, installation default at /admin/preferences) is left
    out. NULL there means "inherit the installation default", so the filter
    coalesces against the resolved default rather than testing the column.
  * **...except for the post's author** (`include_hidden?: true`), who was told
    the member's name in the like notification the moment it happened. Hiding
    it from them afterwards would be a promise we cannot keep, and it is their
    own post's page.
  * **The count is not touched.** This list is capped and filtered; the like
    total (`shown_counts/1`) stays the true total, and the renderer folds the
    difference into the `+N` chip — a number that was public anyway.

  Hidden accounts (frozen, deactivated, suspended, unreachable) and unconfirmed
  ones drop out like they do from every other public people list; their likes
  still count, they simply have no face to show.
  """
  def post_likers(post_id, opts \\ []) when is_binary(post_id) do
    # Matches `<.avatar_stack>`'s cap, so the row never queries rows it would
    # only fold into `+N` — and the agent formats name exactly the same people
    # the page does.
    limit = Keyword.get(opts, :limit, @likers_shown)

    from(l in PostLike,
      join: u in User,
      on: u.id == l.user_id,
      where: l.post_id == ^post_id,
      where: account_confirmed_row(u) and not account_hidden_row(u),
      # UUID v7: id order is creation order, so this is newest liker first.
      order_by: [desc: l.id],
      limit: ^limit,
      select: u
    )
    |> scope_attributed(Keyword.get(opts, :include_hidden?, false))
    |> Repo.all()
  end

  @doc """
  Who liked a post, as a list a client can walk (`Vutuv.Keyset`) — the same
  people `post_likers/2` names on the permalink, with the same two guards
  (a hidden or unconfirmed account is nobody, and a member who asked not to be
  named beside their likes is not named).

  Bounded on the **member's** id rather than on the like's, because that is the
  id the response carries and the one a client hands back.
  """
  def post_liker_accounts(post_id, opts \\ []) when is_binary(post_id) do
    from(l in PostLike,
      join: u in User,
      as: :liker,
      on: u.id == l.user_id,
      where: l.post_id == ^post_id,
      where: account_confirmed_row(u) and not account_hidden_row(u),
      select: u
    )
    |> scope_attributed(false)
    |> Keyset.scope(opts, {:liker, :id})
    |> Repo.all()
    |> Keyset.restore(opts)
  end

  @doc """
  Who reshared a post, as a walkable list — the mirror of
  `post_liker_accounts/2`.

  Carries the hidden/unconfirmed guard too: a reshare is not an endorsement a
  suspended account gets to keep making in public. There is no attribution
  switch here, because resharing is already a public act under your own name.
  """
  def post_reposter_accounts(post_id, opts \\ []) when is_binary(post_id) do
    from(r in PostRepost,
      join: u in User,
      as: :reposter,
      on: u.id == r.user_id,
      where: r.post_id == ^post_id,
      where: account_confirmed_row(u) and not account_hidden_row(u),
      select: u
    )
    |> Keyset.scope(opts, {:reposter, :id})
    |> Repo.all()
    |> Keyset.restore(opts)
  end

  @doc "How many likers the permalink names before the rest fold into `+N`."
  def likers_shown, do: @likers_shown

  defp scope_attributed(query, true), do: query

  defp scope_attributed(query, false) do
    default = Prefs.default(:like_attribution?)

    from([_l, u] in query,
      where: coalesce(field(u, :like_attribution?), type(^default, :boolean)) == true
    )
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

  defp engage(schema, kind, actor, %Post{} = post, acting_user \\ nil) do
    if visible_to?(post, actor) do
      # Liking, bookmarking or reposting a post is proof the actor read it, so
      # whatever the notifications feed has to say about that post is old news
      # — including on the idempotent repeat, which is still somebody acting on
      # a post in front of them. A page has no such feed, so nothing to mark.
      if match?(%User{}, actor), do: Vutuv.Activity.mark_post_seen(actor.id, post.id)

      {fields, conflict_target} = engagement_keys(actor, post, acting_user)

      case Vutuv.Engagement.insert_if_new(schema, fields, conflict_target) do
        :exists ->
          {:ok, :noop}

        {:inserted, row} ->
          broadcast_engagement(kind, actor.id, post.id, true)
          {:ok, row}
      end
    else
      {:error, :not_visible}
    end
  end

  # Which actor column the row is keyed on — and therefore which unique index
  # the upsert has to name. `(post_id, user_id)` cannot serve both: Postgres
  # treats NULLs as distinct, so a page's rows would not conflict with each
  # other at all and it could like the same post without limit.
  defp engagement_keys(%User{} = user, %Post{} = post, _acting_user),
    do: {%{user_id: user.id, post_id: post.id}, [:post_id, :user_id]}

  defp engagement_keys(%Organization{} = page, %Post{} = post, acting_user) do
    {%{
       organization_id: page.id,
       post_id: post.id,
       acting_user_id: acting_user && acting_user.id
     }, [:post_id, :organization_id]}
  end

  # Removing your own engagement needs no visibility check.
  defp disengage(schema, kind, actor, %Post{} = post) do
    # Built as one dynamic: a dynamic composes only inside another dynamic,
    # never inline in a query expression.
    mine = dynamic([e], e.post_id == ^post.id and ^engaged_by(actor))

    {count, _} = Repo.delete_all(from(e in schema, where: ^mine))

    if count > 0, do: broadcast_engagement(kind, actor.id, post.id, false)
    :ok
  end

  # "This actor's row", as a query fragment. Never a bare `e.user_id == ^id`:
  # that column is NULL on a page's row, and the comparison would answer NULL
  # rather than false — the trap this milestone has already paid for repeatedly.
  defp engaged_by(%User{id: id}), do: dynamic([e], e.user_id == ^id)
  defp engaged_by(%Organization{id: id}), do: dynamic([e], e.organization_id == ^id)

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
  defp engagement_viewer_id(%Organization{id: id}), do: id
  defp engagement_viewer_id(id) when is_binary(id), do: id
  # The nil UUID can never match a row: "anonymous" without a NULL arm.
  defp engagement_viewer_id(nil), do: "00000000-0000-0000-0000-000000000000"

  # The shared SELECT behind post_engagement/2 and post_engagement_map/2, so the
  # single-post and batched paths can never drift in what the action bar reads.
  #
  # Each EXISTS tests BOTH actor columns against the one viewer id (issue
  # #1336). That is safe because ids are UUIDs drawn from different tables, so a
  # value can only ever match one of them, and both columns carry a unique index
  # on `(post_id, <actor>)` for the planner to use.
  defp engagement_select(query, viewer_id) do
    query
    |> select([p], engagement_count_select(p))
    |> select_merge([p], %{
      id: p.id,
      liked?:
        fragment(
          "EXISTS (SELECT 1 FROM post_likes l WHERE l.post_id = ? AND ((l.user_id = ?) OR (l.organization_id = ?)))",
          p.id,
          type(^viewer_id, UUIDv7),
          type(^viewer_id, UUIDv7)
        ),
      bookmarked?:
        fragment(
          "EXISTS (SELECT 1 FROM post_bookmarks b WHERE b.post_id = ? AND ((b.user_id = ?) OR (b.organization_id = ?)))",
          p.id,
          type(^viewer_id, UUIDv7),
          type(^viewer_id, UUIDv7)
        ),
      reposted?:
        fragment(
          "EXISTS (SELECT 1 FROM post_reposts r WHERE r.post_id = ? AND ((r.user_id = ?) OR (r.organization_id = ?)))",
          p.id,
          type(^viewer_id, UUIDv7),
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

  Every reader of the post is waiting for this, not only its author: the card
  they already have on screen is showing a placecard where the picture goes, and
  this is what swaps the real one in. So it goes to **two** topics. The post's
  own topic reaches the surfaces that subscribe per shown post — the permalink's
  conversation, the saved list, and the feed for the few cards on it that are
  actually waiting. The **author's** activity topic reaches their own feed and
  their profile page (which every visitor subscribes to, so a stranger reading
  the profile gets the swap too).

  Callers hand in the post id; `Vutuv.Moderation.ImageSubjects` calls it from
  the one place that runs on both the approve and the reject path.
  """
  def broadcast_images_settled(post_id) when is_binary(post_id) do
    # Recompute the flag first, so every listener that re-reads the post sees
    # the state the message announces.
    settled? = refresh_images_pending(post_id)

    event = {:post_images_settled, %{post_id: post_id, settled?: settled?}}
    Phoenix.PubSub.broadcast(Vutuv.PubSub, post_topic(post_id), event)

    # `Vutuv.Activity.broadcast/2` is the house helper for a member's own
    # topic, and it no-ops on a nil recipient — which is exactly the
    # already-deleted-post case.
    author_id = Repo.one(from(p in Post, where: p.id == ^post_id, select: p.user_id))
    Vutuv.Activity.broadcast(author_id, event)

    :ok
  end

  def broadcast_images_settled(_post_id), do: :ok

  @doc """
  Recomputes a post's `images_pending?` flag from its photos, and answers
  whether **this call** is the one that saw the last of them settle (issue
  #1104).

  The one owner of that column. Called at each of the three moments it can
  change: a post is created, a post is edited (which can attach fresh photos),
  and a scan settles. It is written with a guarded `update_all` so two scans
  finishing at once cannot both claim the settle.
  """
  def refresh_images_pending(post_id) when is_binary(post_id) do
    {changed?, pending?} = recompute_images_pending(post_id)
    changed? and not pending?
  end

  def refresh_images_pending(_post_id), do: false

  # `{changed?, pending?}` — the write and the resulting state. The write is
  # guarded on the value actually differing, so two scans finishing at the same
  # moment cannot both report the settle.
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
  Whether at least one of this post's photos is still waiting for the AI image
  scan.

  It says nothing about who may read the post — that is `visible_to?/2`, and
  the answer has been "everybody it is addressed to" since the picture stopped
  holding the text back. What it drives is the **author's** progress panel
  (`VutuvWeb.PostComponents.photo_check_progress/1`); other readers learn the
  same thing from the placecard standing in for the picture itself.
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
    #
    # Both joins are LEFT because a post has one of two kinds of author (issue
    # #1334) and the `where` below then says which one this row must satisfy.
    # An inner join to `users` was what kept every organization post out of
    # search — silently, since a missing result looks like a missing post.
    #
    # `scope_visible(nil)` needs nothing added for them: an organization post
    # carries no denials, and the author-hidden arm reads the left-joined row
    # with `IS NOT NULL` tests, which are `false` (never NULL) on the absent
    # row — so the post passes rather than being swallowed by three-valued
    # logic. The page's own standing is the `organization_public_row/1` below.
    from(p in Post,
      as: :post,
      left_join: u in assoc(p, :user),
      as: :author,
      left_join: o in assoc(p, :organization),
      as: :search_organization,
      where:
        (not is_nil(p.user_id) and u.email_confirmed? == true) or
          (not is_nil(p.organization_id) and organization_public_row(o))
    )
    |> filter_body_search(value)
    |> filter_posts_by_tag(tag, Keyword.get(opts, :exact, false))
    |> order_public_search(value)
    |> limit(^limit)
    |> preload([author: u, search_organization: o], user: u, organization: o)
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
  # Both filings count, the same way they do on the tag page
  # (`visible_tagged_posts_query/0`): the composer's tag field and a `#hashtag`
  # in the body. Two EXISTS rather than a union subquery, because EXISTS stops
  # at the first hit and neither can duplicate the post.
  defp filter_posts_by_tag(query, nil, _exact?), do: query

  defp filter_posts_by_tag(query, tag, exact?) do
    field_match = tag_filing_match(PostTag, tag, exact?)
    body_match = tag_filing_match(PostHashtag, tag, exact?)

    where(query, [], exists(subquery(field_match)) or exists(subquery(body_match)))
  end

  defp tag_filing_match(schema, tag, true) do
    from(f in schema,
      join: t in assoc(f, :tag),
      where:
        f.post_id == parent_as(:post).id and
          (fragment("lower(?)", t.name) == ^tag or t.slug == ^tag)
    )
  end

  defp tag_filing_match(schema, tag, false) do
    infix = contains(tag)

    from(f in schema,
      join: t in assoc(f, :tag),
      where:
        f.post_id == parent_as(:post).id and
          (ilike(t.name, ^infix) or ilike(t.slug, ^infix))
    )
  end

  @doc """
  The public posts carrying at least one tag (anonymous view), the filing
  exposed as the named binding `:post_tag` (with `post_id` / `tag_id`). The one
  visibility gate behind the tag page's timeline (`Vutuv.Tags.Timeline` narrows
  it to one tag through `tag_posts_query/1`), the tag indexability bar
  (`Vutuv.Tags.indexable_tags_query/0` groups it by tag id) and the hashtag-link
  gate (`Vutuv.Tags.linkable_slugs/1`), so none of them can disagree about which
  posts count.

  A post reaches a tag two ways, and this is where they meet: the composer's tag
  field (`Vutuv.Posts.PostTag`, what the card renders as chips) and a `#hashtag`
  in the body (`Vutuv.Posts.PostHashtag`). `union` rather than `union_all`, so a
  post that does both — a "berlin" chip over a body saying `#berlin` — is one
  row and not two; every caller counts and pages on these rows.
  """
  def visible_tagged_posts_query do
    filings =
      union(
        from(pt in PostTag, select: %{post_id: pt.post_id, tag_id: pt.tag_id}),
        ^from(ph in PostHashtag, select: %{post_id: ph.post_id, tag_id: ph.tag_id})
      )

    # LEFT joins, because a page files posts under tags exactly as a member
    # does — a `#hashtag` in the body writes the same `post_hashtags` row. With
    # an inner join to `users` the filing happened and the tag page did not show
    # it, which is the worst of the two states: the data says it is there.
    from(p in Post,
      left_join: u in assoc(p, :user),
      as: :author,
      left_join: o in assoc(p, :organization),
      as: :tag_organization,
      join: pt in subquery(filings),
      as: :post_tag,
      on: pt.post_id == p.id,
      where:
        (not is_nil(p.user_id) and u.email_confirmed? == true) or
          (not is_nil(p.organization_id) and organization_public_row(o))
    )
    |> scope_visible(nil)
  end

  @doc """
  The public posts carrying `tag` (unordered, unpaginated) — the vutuv half of
  the tag page's timeline, which `Vutuv.Tags.Timeline` filters, sorts and pages.
  """
  def tag_posts_query(%Tag{} = tag) do
    from([post_tag: pt] in visible_tagged_posts_query(), where: pt.tag_id == ^tag.id)
  end

  @doc """
  The associations every rendered post carries. Public so a caller that loads
  posts through its own query (`Vutuv.Tags.Timeline`) preloads exactly what the
  card needs, rather than keeping a second list that drifts.
  """
  def render_preloads, do: post_preloads()

  @doc """
  The feed a **page** reads (issue #1336): what the members and pages it follows
  have published, newest first, same entry shape and cursor as `feed_page/2`.

  Four sources, not six: posts by the members and pages it follows, posts
  carrying a tag it follows, and posts from the accounts it follows on other
  networks. The two it does not have are reposts (a page reposts nothing) and
  remote boosts, which travel through a member's repost. The rule throughout has
  been to add a source only once a page can actually fill it, rather than
  shipping empty queries per page load.

  **A member's post is visible here only if it is public.** Denials name users,
  groups and follow relationships, and a page is none of those, so it can never
  *be* the audience of a restricted post — `scope_visible(query, nil)`, the
  anonymous public gate, is the honest reading rather than something new.

  `viewer:` is the member currently acting as the page. It decorates the entries
  (their own likes, bookmarks and reposts), because the action bar under each
  card belongs to the person, not to the page: a page has no likes of its own.
  It never widens what the feed contains — that is the page's follow graph
  alone, so two publishers reading it see the same posts.
  """
  def organization_feed_page(%Organization{} = page, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_feed_limit)
    cursor = Keyword.get(opts, :cursor)
    viewer = Keyword.get(opts, :viewer)

    sources = [
      &organization_feed_member_posts(page, &1, &2),
      &organization_feed_page_posts(page, &1, &2),
      &organization_feed_tag_posts(page, &1, &2),
      # The accounts it follows on other networks (issue #1336's last point).
      # The fourth and last source a page can fill.
      &Vutuv.Fediverse.organization_feed_remote_posts(page, &1, &2)
    ]

    page_result = Vutuv.FeedPage.paginate(sources, limit, cursor)

    %{page_result | entries: decorate_feed_entries(page_result.entries, viewer)}
  end

  defp organization_feed_member_posts(%Organization{id: page_id}, fetch_n, cursor) do
    from(p in Post,
      join: u in assoc(p, :user),
      as: :author,
      where: p.user_id in subquery(members_followed_by_organization(page_id)),
      where: account_confirmed_row(u) and not account_hidden_row(u),
      order_by: [desc: p.inserted_at, desc: p.id],
      limit: ^fetch_n
    )
    |> scope_visible(nil)
    |> posts_at_or_before(cursor)
    |> Repo.all()
    |> Enum.map(&%{id: "post-#{&1.id}", post: &1, reposted_by: nil, at: &1.inserted_at})
  end

  defp organization_feed_page_posts(%Organization{id: page_id}, fetch_n, cursor) do
    from(p in Post,
      join: o in Organization,
      as: :organization,
      on: o.id == p.organization_id,
      where: p.organization_id in subquery(pages_followed_by_organization(page_id)),
      where: organization_public_row(o),
      where: is_nil(p.frozen_at),
      order_by: [desc: p.inserted_at, desc: p.id],
      limit: ^fetch_n
    )
    |> posts_at_or_before(cursor)
    |> Repo.all()
    |> Enum.map(&%{id: "post-#{&1.id}", post: &1, reposted_by: nil, at: &1.inserted_at})
  end

  # Posts carrying a tag the page follows (issue #1336) — the topic source, the
  # third and last one a page can fill today. Members' posts only: a page's own
  # posts already arrive through the source above when it follows that page, and
  # letting a tag pull them in as well would show the same post twice.
  #
  # Public posts only, for the same reason as the member source: a page can
  # never be a denial's audience.
  defp organization_feed_tag_posts(%Organization{id: page_id}, fetch_n, cursor) do
    from(p in Post,
      join: u in assoc(p, :user),
      as: :author,
      join: pt in PostTag,
      on: pt.post_id == p.id,
      where: pt.tag_id in subquery(tags_followed_by_organization(page_id)),
      where: account_confirmed_row(u) and not account_hidden_row(u),
      distinct: true,
      order_by: [desc: p.inserted_at, desc: p.id],
      limit: ^fetch_n
    )
    |> scope_visible(nil)
    |> posts_at_or_before(cursor)
    |> Repo.all()
    |> Enum.map(&%{id: "post-#{&1.id}", post: &1, reposted_by: nil, at: &1.inserted_at})
  end

  defp tags_followed_by_organization(page_id) do
    from(tf in Vutuv.Tags.TagFollow,
      where: tf.organization_id == ^page_id,
      select: tf.tag_id
    )
  end

  # The two halves of a page's follow graph. Named functions rather than inline
  # subqueries for the reason the milestone keeps relearning: a nullable column
  # feeding an `IN` needs one place to fix, not several.
  defp members_followed_by_organization(page_id) do
    from(c in Follow,
      where: c.follower_organization_id == ^page_id and c.muted == false,
      where: not is_nil(c.followee_id),
      select: c.followee_id
    )
  end

  defp pages_followed_by_organization(page_id) do
    from(c in Follow,
      where: c.follower_organization_id == ^page_id and c.muted == false,
      where: not is_nil(c.followee_organization_id),
      select: c.followee_organization_id
    )
  end

  @doc """
  The languages the member marked as their own (the chips on
  /settings/preferences), normalized for reading: `[]` when they never chose
  any. The one raw read of the `feed_languages` column — its two consumers,
  the hide filter below and the translate mode's "is this post foreign?"
  test (`VutuvWeb.Live.PostTranslations`), interpret an empty choice
  differently BY DESIGN: hide mode with no chips hides nothing
  (`feed_language_filter/1` answers nil), while translate mode with no
  chips treats only the UI locale as the member's own.
  """
  def chosen_feed_languages(%User{feed_languages: chosen}), do: chosen || []

  @doc """
  The chosen-languages list the viewer's feed HIDES by (issue #1461), or nil
  when nothing is hidden — which is almost everyone: only the "hide" mode
  with a real language selection filters at all. The one place this pair of
  columns is interpreted for the feed queries.
  """
  def feed_language_filter(%User{} = viewer) do
    chosen = chosen_feed_languages(viewer)

    if Vutuv.Prefs.get(viewer, :feed_foreign_posts) == "hide" and chosen != [] do
      chosen
    end
  end

  @doc """
  Narrows a feed source query to the chosen languages. nil = no filter. The
  clause is spelled `is_nil or in` on purpose: NULL (undeclared) never hides
  (the organization milestone's NOT-IN/NULL lesson), and the binding is the
  query's root — every feed source roots at its language-bearing schema.
  """
  def language_scope(query, nil), do: query

  def language_scope(query, chosen) when is_list(chosen) do
    from(x in query, where: is_nil(x.language) or x.language in ^chosen)
  end

  @doc """
  `language_scope/2` for a source whose language-bearing schema is a JOIN
  rather than the root — the join carries `as: :language_source`. A left-join
  NULL row passes (its language reads NULL), which is exactly right for the
  boost source's local half.
  """
  def named_language_scope(query, nil), do: query

  def named_language_scope(query, chosen) when is_list(chosen) do
    from([language_source: x] in query, where: is_nil(x.language) or x.language in ^chosen)
  end

  @doc """
  The in-memory twin of `language_scope/2`, for rows a query already fetched
  (the boost source's local half lives outside its query). Same rule, one
  owner: NULL — the filter's or the row's — never hides.
  """
  def language_visible?(_language, nil), do: true

  def language_visible?(language, chosen) when is_list(chosen),
    do: is_nil(language) or language in chosen

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

  `filter:` narrows the feed to one **source tab** — `:all` (the default),
  `:vutuv` or `:fediverse`; see `feed_sources/2`.
  """
  def feed_page(%User{} = viewer, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_feed_limit)
    cursor = Keyword.get(opts, :cursor)
    filter = Keyword.get(opts, :filter, :all)

    page = Vutuv.FeedPage.paginate(feed_sources(viewer, filter), limit, cursor)

    %{page | entries: decorate_feed_entries(page.entries, viewer)}
  end

  # The six sources the merged feed pulls from, narrowed to the reader's tab.
  #
  # The two tabs partition the feed by **what kind of post an entry carries**
  # (`remote_feed_entry?/1`) — the same question the renderer asks to pick a
  # card, so every entry lands on exactly one tab and the two together are
  # "All". That rule decides the one source that produces both kinds:
  # `feed_remote_boosts/4` (issue #1167) carries a cached remote post when the
  # boosted thing lives out there, and a plain vutuv post when a followed
  # account passed a member's post on — the latter *is* a vutuv post, so it
  # belongs on the vutuv tab even though it arrived through the fediverse.
  # `:only` narrows that source inside its own query rather than by filtering
  # rows afterwards, so a page is never short of what the paginator fetched
  # for it (which is what decides `more?`).
  defp feed_sources(viewer, :vutuv) do
    [
      &feed_post_items(viewer, &1, &2),
      &feed_organization_post_items(viewer, &1, &2),
      &feed_repost_items(viewer, &1, &2),
      &feed_tag_items(viewer, &1, &2),
      &Vutuv.Fediverse.feed_remote_boosts(viewer, &1, &2, only: :local)
    ]
  end

  defp feed_sources(viewer, :fediverse) do
    [
      &Vutuv.Fediverse.feed_remote_posts(viewer, &1, &2),
      &Vutuv.Fediverse.feed_remote_reposts(viewer, &1, &2),
      &Vutuv.Fediverse.feed_remote_reply_reposts(viewer, &1, &2),
      &Vutuv.Fediverse.feed_remote_boosts(viewer, &1, &2, only: :remote)
    ]
  end

  defp feed_sources(viewer, _all) do
    [
      &feed_post_items(viewer, &1, &2),
      # What the organizations the viewer follows have published (issue #1336).
      &feed_organization_post_items(viewer, &1, &2),
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
      &Vutuv.Fediverse.feed_remote_boosts(viewer, &1, &2),
      # Seventh: **replies** from another network that people here have
      # passed on (issue #1275). The same act as the fifth source one table
      # over: a reply arrived under somebody's vutuv post, a member here
      # thought it worth carrying, and that is how it reaches readers who
      # never opened that conversation.
      &Vutuv.Fediverse.feed_remote_reply_reposts(viewer, &1, &2)
    ]
  end

  @doc """
  Maps a raw feed-tab string (a phx-value) to one of the filters
  `feed_page/2` understands, defaulting to `:all` for anything unrecognised.
  """
  def normalize_feed_filter(type)
  def normalize_feed_filter("vutuv"), do: :vutuv
  def normalize_feed_filter("fediverse"), do: :fediverse
  def normalize_feed_filter(_type), do: :all

  @doc """
  The source tab `viewer` last chose on `/feed` (issue #1499) — the tab their
  next visit opens on.

  Read straight off the column the session already loaded, so the opening
  filter costs no query and the very first (dead) render can compute the right
  page. It is the *stored* value, not the effective one: the caller still has
  to fold it back to `:all` when `fediverse_feed_available?/1` says the tab bar
  has nothing to show, or a member whose fediverse content dried up would open
  on a tab they cannot see to leave.
  """
  def remembered_feed_filter(%User{feed_source: source}), do: normalize_feed_filter(source)

  @doc """
  Remembers `filter` as `user`'s feed tab for the next visit.

  A narrow `update_all` on the one column rather than a changeset: a socket's
  `%User{}` was loaded at mount and can be hours old by the time a tab is
  clicked, so writing the whole struct back would undo whatever else changed
  meanwhile — from another device, or from a settings page in the next tab.
  For the same reason it does not first ask whether the value differs; that
  question cannot be answered from a struct that may be stale, and the write
  is one row by primary key. Last click wins, which is what a "last chosen"
  value means.
  """
  def remember_feed_filter(%User{} = user, filter) do
    stored = if filter in [:vutuv, :fediverse], do: to_string(filter)

    {1, nil} =
      Repo.update_all(from(u in User, where: u.id == ^user.id), set: [feed_source: stored])

    :ok
  end

  @doc """
  Whether the feed tab `filter` shows `entry` — the in-memory twin of the
  source split in `feed_sources/2`, for the entries that arrive live over
  PubSub rather than through a query.
  """
  def feed_filter_accepts?(:vutuv, entry), do: not remote_feed_entry?(entry)
  def feed_filter_accepts?(:fediverse, entry), do: remote_feed_entry?(entry)
  def feed_filter_accepts?(_all, _entry), do: true

  @doc """
  Whether `viewer`'s feed can show anything from another network at all — the
  gate on the source tabs (issue #1267).

  Without it the tabs are noise for a member the fediverse never reaches:
  "Fediverse" is permanently empty and "vutuv" is therefore the same list as
  "All", so all three offer one timeline under three names.

  It asks the **same sources the Fediverse tab renders** rather than a
  member-level flag, because no flag gets this right. The obvious candidate,
  `Vutuv.Fediverse.federated?/1`, is about *publishing outward* (their opt-in,
  their actor, their standing) and answers a different question; so does "do
  they follow any remote account". Both would hide the tabs from a member who
  is not in the fediverse in any sense yet still has remote posts in their
  feed, because somebody they follow **here** reshared one (issue #1166,
  `feed_remote_reposts/3` — scoped to vutuv followees, so it reaches a member
  with no fediverse involvement whatsoever). Asking the sources cannot drift
  from what the tab shows, which a hand-maintained condition would.

  One row is enough, so each source is asked for exactly one and `Enum.any?/2`
  stops at the first hit: a member with remote follows pays a single indexed
  `LIMIT 1`, and only a member with nothing pays all three. The sources
  themselves are newest-first and unbounded below, so a single old remote post
  is found just as reliably as a fresh one. Every source short-circuits to
  `[]` while the installation switch is off, so this covers `enabled?/0` too
  and no second check is needed beside it.
  """
  def fediverse_feed_available?(%User{} = viewer) do
    viewer
    |> feed_sources(:fediverse)
    |> Enum.any?(fn fetch -> fetch.(1, nil) != [] end)
  end

  @doc """
  Whether the tab `source` has anything for `viewer` stamped at or after
  `since` — what the feed asks before dotting a tab it is not looking at
  (issue #1503).

  Same shape as `fediverse_feed_available?/1` one question narrower, and for
  the same reason: **only the reader's own sources know whether a post reaches
  them**. A mute, a follow still merely requested, an audience narrower than
  public, a language they filter out and the resharer's own standing all decide
  per member, so the write that triggered this cannot fan out an answer — it
  can only say "something landed, go and look". Each source is asked for its
  newest row and `Enum.any?/2` stops at the first that qualifies.

  It answers "there is something at the top of that tab at least as new as what
  just landed", not "that exact post reached you". The two come apart only when
  a server delivers a post published well before now: then the row this finds
  is the tab's newest rather than the arrival. A tab with fresh content at the
  top is still what the dot promises, so that is the conservative side to err
  on — the side it must never err on is a post the reader may not see, which is
  why the sources answer rather than the fan-out.
  """
  def feed_source_since?(%User{} = viewer, source, %NaiveDateTime{} = since)
      when source in [:vutuv, :fediverse] do
    viewer
    |> feed_sources(source)
    |> Enum.any?(fn fetch ->
      case fetch.(1, nil) do
        [entry | _] -> NaiveDateTime.compare(entry.at, since) != :lt
        [] -> false
      end
    end)
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

  # What the reader has already done with each of the page's remote posts
  # (issues #1164, #1166 and #1276), read once for the whole page. It rides the
  # entry rather than a socket-level set because the feed re-renders a card by
  # re-inserting its entry into the stream, so the state a card draws from has
  # to live on the entry it draws.
  defp attach_remote_likes(remote, viewer) do
    posts = Enum.map(remote, & &1.remote_post)
    marks = Vutuv.Fediverse.mark_lookup(posts, viewer)

    Enum.map(remote, &Map.put(&1, :marks, marks.(&1.remote_post)))
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
  def remote_feed_entry?(entry), do: not is_nil(entry[:remote_post]) or remote_reply_entry?(entry)

  @doc """
  Whether this row is a **reply** from another network rather than a cached post
  (issue #1275). The second remote row shape, and the one every reader of
  `entry.remote_post` has to be asked first — that field is nil here, and the
  card, the content filter and the id all come from `entry.note` instead.
  """
  def remote_reply_entry?(entry), do: not is_nil(entry[:note])

  defp feed_post_items(%User{id: viewer_id} = viewer, fetch_n, cursor) do
    from(p in Post,
      join: u in assoc(p, :user),
      as: :author,
      where: p.user_id == ^viewer_id or p.user_id in subquery(followees_of(viewer_id)),
      where: p.user_id == ^viewer_id or account_confirmed_row(u),
      order_by: [desc: p.inserted_at, desc: p.id],
      limit: ^fetch_n
    )
    |> scope_visible(viewer)
    |> language_scope(feed_language_filter(viewer))
    |> posts_at_or_before(cursor)
    |> Repo.all()
    |> Enum.map(&%{id: "post-#{&1.id}", post: &1, reposted_by: nil, at: &1.inserted_at})
  end

  # Posts by the organizations the viewer follows (issue #1336). Its own source
  # rather than a widened `feed_post_items/3`: that one inner-joins `users` to
  # gate on the author's account standing, and an organization has no account
  # standing — what stands in for it is `organization_public_row/1` (active and
  # not frozen), which is a different table and a different question.
  #
  # No `scope_visible/2`: an organization post carries no denials by
  # construction (`create_organization_post/3`), so the only thing that can hide
  # one is the moderation freezer, which is exactly what the guard below is.
  defp feed_organization_post_items(%User{id: viewer_id} = viewer, fetch_n, cursor) do
    from(p in Post,
      join: o in Organization,
      as: :organization,
      on: o.id == p.organization_id,
      where: p.organization_id in subquery(followed_organizations_of(viewer_id)),
      where: organization_public_row(o),
      where: is_nil(p.frozen_at),
      order_by: [desc: p.inserted_at, desc: p.id],
      limit: ^fetch_n
    )
    |> language_scope(feed_language_filter(viewer))
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
      # LEFT on the resharer too (issue #1336): a page can repost now, and its
      # row has a NULL `user_id`. An inner join to `users` was right while only
      # a member could reshare and became a silent filter the day a page could —
      # the same shape that, one join down, meant a member could repost a page's
      # news and it reached nobody.
      left_join: reposter in User,
      on: reposter.id == r.user_id,
      left_join: rp in assoc(r, :organization),
      as: :resharer_organization,
      # LEFT, because the reposted post may have been published by an
      # organization (issue #1334).
      left_join: u in assoc(p, :user),
      as: :author,
      left_join: o in assoc(p, :organization),
      as: :repost_organization,
      where: ^repost_reaches_me(viewer_id),
      where: ^resharer_is_shown(viewer_id),
      # A repost must not amplify an author the site hides. For a member that is
      # their account standing; for a page it is the page's own
      # (`organization_public_row/1`), so a frozen page stops being passed on.
      where:
        (not is_nil(p.user_id) and (p.user_id == ^viewer_id or account_confirmed_row(u))) or
          (not is_nil(p.organization_id) and organization_public_row(o)),
      # A third party's repost must not carry a blocked author's post into
      # the viewer's feed (the direct path is already cut: blocking severed
      # the follow).
      where: p.user_id not in subquery(blocked_either_way(viewer_id)),
      order_by: [desc: r.inserted_at, desc: r.id],
      limit: ^fetch_n,
      select: {r.id, r.inserted_at, p, reposter, rp}
    )
    |> scope_visible(viewer)
    |> language_scope(feed_language_filter(viewer))
    |> reposts_at_or_before(cursor)
    |> Repo.all()
    |> Enum.map(fn {id, at, post, reposter, page} ->
      %{id: "repost-#{id}", post: post, reposted_by: reposter || page, at: at}
    end)
  end

  # Reshared by me, by somebody I follow, or by a page I follow (issue #1336).
  defp repost_reaches_me(viewer_id) do
    dynamic(
      [_p, r],
      r.user_id == ^viewer_id or r.user_id in subquery(followees_of(viewer_id)) or
        r.organization_id in subquery(followed_organizations_of(viewer_id))
    )
  end

  # A reshare must not amplify a resharer the site hides: account standing for a
  # member, the page's own standing for a page.
  #
  # Each gate is scoped to the actor it is about (`not is_nil(r.user_id) and …`)
  # and never OR-ed bare. `account_confirmed_row/1` reads
  # `is_nil(u.email_confirmed?) or …`, and on a LEFT-joined **missing** row that
  # `is_nil` is TRUE — so the member gate passed vacuously for every page
  # reshare and a frozen page kept being amplified. The macro was written for an
  # inner join, where the row always exists.
  defp resharer_is_shown(viewer_id) do
    dynamic(
      [_p, r, reposter, rp],
      r.user_id == ^viewer_id or
        (not is_nil(r.user_id) and account_confirmed_row(reposter)) or
        (not is_nil(r.organization_id) and organization_public_row(rp))
    )
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
          left_join: u in assoc(p, :user),
          as: :author,
          left_join: o in assoc(p, :organization),
          as: :tag_organization,
          where: ^tag_source_member_gate(viewer_id),
          where: ^tag_source_organization_gate(viewer_id),
          where: exists(subquery(tag_match)),
          order_by: [desc: p.inserted_at, desc: p.id],
          limit: ^fetch_n
        )
        |> scope_visible(viewer)
        |> language_scope(feed_language_filter(viewer))
        |> posts_at_or_before(cursor)
        |> Repo.all()
        |> Enum.map(&%{id: "tagpost-#{&1.id}", post: &1, reposted_by: nil, at: &1.inserted_at})
    end
  end

  defp followees_of(viewer_id) do
    # Muted follows stay in place (the relationship and any "vernetzt" status
    # are untouched) but their author's posts drop out of the viewer's feed.
    #
    # `not is_nil(followee_id)` keeps the organization follows (issue #1336) out
    # of a **member** id list. It is not tidiness: these lists feed `IN` and —
    # worse — `NOT IN` subqueries, and `x NOT IN (…, NULL)` is never true in
    # SQL, so one organization follow would silently empty every discovery tier
    # that excludes who you already follow.
    from(c in Follow,
      where: c.follower_id == ^viewer_id and c.muted == false and not is_nil(c.followee_id),
      select: c.followee_id
    )
  end

  # "Somebody new to me, whom I am allowed to see", for a post written by a
  # member. Guarded by `is_nil(p.user_id)` first, because `NULL != id` and
  # `NULL NOT IN (…)` are both NULL: without the guard all three conditions
  # would read false on an organization post and drop it — three separate
  # silent exclusions in one query.
  defp tag_source_member_gate(viewer_id) do
    dynamic(
      [post: p, author: u],
      is_nil(p.user_id) or
        (p.user_id != ^viewer_id and
           p.user_id not in subquery(all_followees_of(viewer_id)) and
           p.user_id not in subquery(blocked_either_way(viewer_id)) and
           account_confirmed_row(u))
    )
  end

  # The same rule for a post written by a page: it must be public, and it must
  # not be one I already follow — a page I follow reaches me through
  # `feed_organization_post_items/3`, so letting its tagged posts in here too
  # would show them twice. Muted follows count as followed, exactly as
  # `all_followees_of/1` treats members.
  defp tag_source_organization_gate(viewer_id) do
    dynamic(
      [post: p, tag_organization: o],
      is_nil(p.organization_id) or
        (organization_public_row(o) and
           p.organization_id not in subquery(all_followed_organizations_of(viewer_id)))
    )
  end

  # Every page the viewer follows, muted or not — the dedupe set for the tag
  # source, the organization twin of `all_followees_of/1`. Muting a page means
  # "not in my feed", so a muted page's tagged post must not sneak back in by
  # the side door.
  defp all_followed_organizations_of(viewer_id) do
    from(c in Follow,
      where: c.follower_id == ^viewer_id and not is_nil(c.followee_organization_id),
      select: c.followee_organization_id
    )
  end

  # The organizations whose posts belong in this viewer's feed: the pages they
  # follow and have not muted (issue #1336).
  defp followed_organizations_of(viewer_id) do
    from(c in Follow,
      where: c.follower_id == ^viewer_id and c.muted == false,
      where: not is_nil(c.followee_organization_id),
      select: c.followee_organization_id
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
  # A page reading its OWN feed carries no reposts (it does not read the
  # members' repost source), so there is no roster to attach and no viewer whose
  # follow graph would scope one. Nil is a real case here, not a slip.
  defp attach_reposters(entries, nil), do: Enum.map(entries, &Map.put(&1, :reposters, []))

  defp attach_reposters(entries, %User{} = viewer) do
    # Keyed on "there is a resharer", not on "the resharer is a member": since
    # issue #1336 a page can reshare too, and a `%User{}` pattern here quietly
    # dropped those entries back to an empty roster — the banner then named
    # nobody on a post that was in the feed precisely because a page reshared it.
    post_ids = for %{reposted_by: by} = entry <- entries, not is_nil(by), do: entry.post.id
    rosters = reposter_rosters(post_ids, viewer)

    Enum.map(entries, fn
      %{reposted_by: nil} = entry ->
        Map.put(entry, :reposters, [])

      entry ->
        reposters = Map.get(rosters, entry.post.id, [entry.reposted_by])
        entry |> Map.put(:reposters, reposters) |> Map.put(:reposted_by, hd(reposters))
    end)
  end

  defp reposter_rosters([], _viewer), do: %{}

  defp reposter_rosters(post_ids, %User{id: viewer_id}) do
    # Same widening as `feed_repost_items/3` above, and for the same reason: the
    # banner names who reshared, and a page is now one of the answers.
    from(r in PostRepost,
      left_join: u in User,
      on: u.id == r.user_id,
      left_join: rp in assoc(r, :organization),
      where: r.post_id in ^post_ids,
      where:
        r.user_id == ^viewer_id or r.user_id in subquery(followees_of(viewer_id)) or
          r.organization_id in subquery(followed_organizations_of(viewer_id)),
      # Scoped per actor kind — see the note in `feed_repost_items/3`: a bare
      # `account_confirmed_row(u)` is TRUE on a left-joined missing row.
      where:
        r.user_id == ^viewer_id or
          (not is_nil(r.user_id) and account_confirmed_row(u)) or
          (not is_nil(r.organization_id) and organization_public_row(rp)),
      order_by: [desc: r.inserted_at, desc: r.id],
      select: {r.post_id, u, rp}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), fn {_post_id, user, page} -> user || page end)
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
  `profile_posts/3` as a list a client can walk: the same three legs
  (`author_timeline_query/3`) and the same visibility, ordered and bounded by
  the **post** id rather than by when the entry was made.

  Two deliberate differences from the website's version, both forced by what a
  Mastodon client hands back. It returns one id per status, and for a repost
  that id is the id of the post being reshared, not of the reshare — so the
  post id is the only column the walk can be bounded on, and the order has to
  match it or the page repeats and skips rows. And replies are **not** folded
  under the post they answer (`collapse_profile_threads/1`): a client's account
  timeline is a flat list, and folding would make a full page come back short,
  which reads to the client as the end of the list.
  """
  def author_statuses(%User{} = author, viewer, opts \\ []) do
    author
    |> author_timeline_query(viewer, :all)
    |> Keyset.scope(opts, :post_id)
    |> Repo.all()
    |> Keyset.restore(opts)
    |> author_entries(author)
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
  most-followed veteran who went quiet does not qualify. Local hearts only
  (this ranks authors, not a shown per-post count, so folded fediverse
  reactions stay out); no self-like filter is needed since a member cannot
  like their own post.

  Viewer-independent, so it is served from the `Vutuv.Posts.TopPosters`
  snapshot when that can answer (10-minute freshness, the
  `Vutuv.Social.PopularUsers` deal) and computed live on a miss.
  """
  def top_recent_posters(days, limit) do
    case TopPosters.top(days, limit) do
      {:ok, users} -> users
      :miss -> compute_top_recent_posters(days, limit)
    end
  end

  @doc false
  def compute_top_recent_posters(days, limit) do
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
  original posts (reposts are engagement rows, so they never appear, and
  replies are filtered out by the same `:posts` predicate the archive's
  "Own posts" tab uses — the member feed says "what I write", not "what I
  answer"), or `:all` for the site-wide feed, which deliberately keeps
  replies. The aggregate feed carries one all-yes Content-Signal and
  cannot signal per item, so it lists only members who opted out of
  nothing — neither of search engines (`noindex?`) nor of AI use
  (`noai?`); an opted-out member's posts still serve through their own
  feed, which signals their choices per response.
  Preloaded like every rendered post; ordered by creation (the UUID v7 id).
  """
  def recent_public_posts(author_or_all, opts \\ [])

  def recent_public_posts(%User{id: author_id}, opts) do
    Post
    |> where([p], p.user_id == ^author_id)
    |> scope_original_kind(:posts)
    |> recent_public(opts)
  end

  def recent_public_posts(:all, opts) do
    # LEFT joins, so a page's posts join the aggregate too (issue #1334). The
    # gate is the same idea on both sides — only authors who opted out of
    # nothing — spelled with each side's own switches: `noindex?`/`noai?` for a
    # member, `seo?`/`geo?` for a page. That is what keeps this feed's
    # permissive Content-Signal honest.
    Post
    |> join(:left, [p], u in assoc(p, :user), as: :author)
    |> join(:left, [p], o in assoc(p, :organization), as: :site_feed_organization)
    |> where(
      [p, author: u, site_feed_organization: o],
      (not is_nil(p.user_id) and u.email_confirmed? and not u.noindex? and not u.noai?) or
        (not is_nil(p.organization_id) and organization_public_row(o) and o.seo? and o.geo?)
    )
    |> recent_public(opts)
  end

  # `opts` may also carry a `Vutuv.Keyset` window (`:max_id` / `:since_id` /
  # `:min_id`), which the Mastodon-compatible public timeline walks the site
  # feed by. Without one this is the plain newest-first page it always was.
  defp recent_public(query, opts) do
    query
    |> scope_visible(nil)
    |> Keyset.scope(opts)
    |> Repo.all()
    |> Keyset.restore(opts)
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
    table = Keyword.get(opts, :pool_table, PopularPosts.default_table())

    case PopularPosts.top(locale_or_english(viewer.locale), table) do
      {:ok, candidates} -> discover_from_pool(viewer, candidates, limit)
      :miss -> discover_by_ladder(viewer, limit)
    end
  end

  # The cheap path: the shared ranking already happened (see
  # `Vutuv.Posts.PopularPosts`), so all that is left is to ask the database
  # which of those candidates this reader may see, and to pick a handful.
  #
  # The ladder's three tiers become one ordering over one candidate set, which
  # is what they always were. It also fixes which way round they run: tiers 1
  # and 2 exclude everyone the viewer follows, so a well-connected member used
  # to pay for two draws that could not fill the card before the third one did
  # the work.
  defp discover_from_pool(%User{} = viewer, candidates, limit) do
    rank = candidates |> Enum.map(& &1.id) |> Enum.with_index() |> Map.new()

    drawn =
      rank
      |> Map.keys()
      |> discover_eligible(viewer)
      |> Enum.group_by(& &1.tier)
      |> Enum.sort_by(fn {tier, _rows} -> tier end)
      # Each tier keeps its own draw — the best-liked @discover_pool of it, in
      # random order — and a lower tier only fills what the ones above left
      # over. The shuffle has to happen inside the tier, not across the whole
      # set: shuffling the lot would throw away the preference the tiers exist
      # to express and suggest someone the reader already follows while a
      # stranger was available.
      |> Enum.flat_map(fn {_tier, rows} ->
        rows
        |> Enum.sort_by(&Map.fetch!(rank, &1.id))
        |> Enum.take(@discover_pool)
        |> Enum.shuffle()
      end)
      |> Enum.uniq_by(& &1.user_id)
      |> Enum.take(limit)

    # Nothing drawn is not the same as nothing to show, and it happens two
    # ways: a brand-new installation where nobody has liked anything yet (so
    # the pool is legitimately empty), or a reader who filtered away every
    # candidate in it. Both land on the same last resort the ladder has always
    # had — the newest eligible posts — so the rail is never permanently blank.
    if drawn == [] do
      discover_recent_draw(discover_candidates(viewer, :strangers), limit)
      |> Enum.map(& &1.id)
      |> load_discover_posts()
    else
      drawn |> Enum.map(& &1.id) |> load_discover_posts()
    end
  end

  # Which of `ids` this viewer may be shown, and in which tier each one lands.
  # Bounded to the pool's ids, so every gate in here is a primary-key lookup
  # rather than a scan — that is what makes re-checking visibility on a
  # minutes-old snapshot affordable.
  defp discover_eligible([], _viewer), do: []

  defp discover_eligible(ids, %User{id: viewer_id}) do
    window = discover_window_start()

    from(p in Post,
      as: :post,
      # An INNER join, so the rail is members only — and that is the intent, not
      # an oversight of #1334: every tier here is about people (strangers you do
      # not follow, one post per author), and `Enum.uniq_by(& &1.user_id)` in the
      # caller would collapse every page's post into one. Widening it to pages
      # means giving them their own tier and their own uniqueness key; until
      # then, keep the join inner — the rail's template reads `post.user`.
      join: u in assoc(p, :user),
      as: :author,
      left_join: f in Follow,
      on: f.follower_id == ^viewer_id and f.followee_id == p.user_id,
      as: :edge,
      where: p.id in ^ids,
      where: p.user_id != ^viewer_id,
      # Muting means "keep this person's posts away from me", in every tier.
      where: is_nil(f.id) or f.muted == false,
      # A post by someone the viewer already reads is only a discovery while
      # it is this fortnight's news; a stranger's may be any age.
      where: is_nil(f.id) or p.inserted_at >= ^window,
      where: p.user_id not in subquery(blocked_either_way(viewer_id)),
      where: account_confirmed_row(u),
      select: %{
        id: p.id,
        user_id: p.user_id,
        tier:
          fragment(
            "CASE WHEN ? IS NULL AND ? >= ? THEN 0 WHEN ? IS NULL THEN 1 ELSE 2 END",
            f.id,
            p.inserted_at,
            ^window,
            f.id
          )
      }
    )
    |> scope_visible(nil)
    |> Repo.all()
  end

  # The uncached path, unchanged: three tiers, each its own ranking scan. Still
  # the answer at boot, for a locale the snapshot does not carry, and in tests.
  defp discover_by_ladder(%User{} = viewer, limit) do
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
      as: :author,
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

  @doc false
  # The viewer-independent half of the rail, ranked once for the whole
  # installation by `Vutuv.Posts.PopularPosts` (which is the only caller):
  # this locale's best-liked eligible posts, one per author, best first.
  #
  # Deliberately no viewer in it. Every gate that depends on who is reading —
  # own posts, follows, mutes, blocks — belongs to the draw, and so does the
  # visibility gate, which is re-applied there because this list ages.
  def compute_discover_pool(locale, pool_size) do
    from(p in Post,
      as: :post,
      join: u in assoc(p, :user),
      as: :author,
      left_join: r in assoc(p, :reply_ref),
      join: lc in subquery(discover_like_counts()),
      on: lc.post_id == p.id,
      as: :like_count,
      where: is_nil(r.id),
      where: fragment("COALESCE(NULLIF(?, ''), 'en')", u.locale) == ^locale,
      where: account_confirmed_row(u),
      where: p.body != "",
      where: lc.likes >= @discover_min_likes,
      distinct: p.user_id,
      order_by: [asc: p.user_id, desc: lc.likes, desc: p.id],
      select: %{id: p.id, user_id: p.user_id, likes: lc.likes, inserted_at: p.inserted_at}
    )
    |> scope_visible(nil)
    |> subquery()
    |> order_by([s], desc: s.likes, desc: s.id)
    |> limit(^pool_size)
    |> select([s], %{id: s.id, user_id: s.user_id, inserted_at: s.inserted_at})
    |> Repo.all()
  end

  # The like counts the rail ranks on, rolled up once for the whole table
  # (likes are far rarer than posts, so this beats a correlated count per
  # candidate row). One figure per post: vutuv's own likes plus the favourites
  # other networks sent (issue #1068) — the same folding `shown_counts/1` and
  # `fetch_recent_posts/4` do, so the rail's bar can never mean something else
  # than the heart the reader sees beside the post. No self-like filter is
  # needed: a member cannot like their own post (enforced in `like_post/2`,
  # issue #1030), so every like is by someone other than the author.
  defp discover_like_counts do
    local = from(l in PostLike, select: %{post_id: l.post_id})
    remote = from(r in Reaction, where: r.kind == "like", select: %{post_id: r.post_id})

    from(x in subquery(union_all(local, ^remote)),
      group_by: x.post_id,
      select: %{post_id: x.post_id, likes: count(x.post_id)}
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
    from(c in Follow,
      where: c.follower_id == ^viewer_id and not is_nil(c.followee_id),
      select: c.followee_id
    )
  end

  # The people the viewer told us to keep quiet — excluded from every
  # discovery tier, including the one that may otherwise suggest a followee.
  defp muted_followees_of(viewer_id) do
    from(c in Follow,
      where: c.follower_id == ^viewer_id and c.muted and not is_nil(c.followee_id),
      select: c.followee_id
    )
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
    author_ids = authors |> Enum.map(&member_id/1) |> Enum.uniq()

    if author_ids == [],
      do: %{},
      else: fetch_recent_posts(author_ids, viewer, per_author, min_likes)
  end

  # Normalizes the "authors" argument of the who-to-follow teaser rail, which
  # its callers pass either as members or as bare ids. Renamed off `author_id`
  # when that became the public accessor for a POST's author (issue #1334) —
  # these two answer different questions and must not share a name.
  defp member_id(%User{id: id}), do: id
  defp member_id(id) when is_binary(id), do: id

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

  @organization_posts_per_page 10

  @doc """
  One page of `organization`'s own posts, newest first (issue #1334), in the
  `%{entries:, total:, more?:, next_offset:}` shape the organization page's
  other "Load more" lists use.

  Much simpler than the member timeline: an organization publishes top-level
  posts and nothing else — no reposts, no replies, no audience denials — so
  there is one leg to page rather than a union to merge. Moderation-held posts
  (a photo still in the AI scan, a frozen post) are kept for the organization's
  own publishers and hidden from everyone else, the way a member sees their own.
  """
  def organization_posts_page(%Organization{} = organization, viewer, opts \\ []) do
    limit = Keyword.get(opts, :limit, @organization_posts_per_page)
    offset = Keyword.get(opts, :offset, 0)
    query = organization_posts_query(organization, viewer)
    total = Repo.aggregate(query, :count)

    entries =
      query
      |> order_by([p], desc: p.id)
      |> limit(^(limit + 1))
      |> offset(^offset)
      |> Repo.all()
      |> preload_posts()

    {shown, rest} = Enum.split(entries, limit)

    %{entries: shown, total: total, more?: rest != [], next_offset: offset + length(shown)}
  end

  @doc "How many of `organization`'s posts `viewer` may see."
  def count_organization_posts(%Organization{} = organization, viewer),
    do: organization |> organization_posts_query(viewer) |> Repo.aggregate(:count)

  @doc """
  `organization_posts_page/3` as a list a client can walk: the same query and
  the same visibility, bounded by a `Vutuv.Keyset` window on the post id
  instead of by an offset.

  A plain list rather than a page map, because the only thing the caller can
  tell a Mastodon client about "more" is the id of the oldest row it just
  received — a total and an offset have nowhere to go in that vocabulary.
  """
  def organization_statuses(%Organization{} = organization, viewer, opts \\ []) do
    organization
    |> organization_posts_query(viewer)
    |> Keyset.scope(opts)
    |> Repo.all()
    |> Keyset.restore(opts)
    |> preload_posts()
  end

  @doc """
  One of `organization`'s posts by id as `viewer` may see it, or `nil` — the
  permalink's lookup.

  Scoped to the organization, so an id belonging to a member's post or to
  another page does not resolve rather than rendering under the wrong name, and
  a garbage id is a miss instead of a cast error. Moderation-held posts stay
  visible to the organization's own publishers, like a member's own frozen post.
  """
  def get_organization_post(%Organization{} = organization, id, viewer) do
    case Vutuv.UUIDv7.cast_or_nil(id) do
      nil ->
        nil

      uuid ->
        organization
        |> organization_posts_query(viewer)
        |> where([p], p.id == ^uuid)
        |> Repo.one()
        |> preload_post()
    end
  end

  defp organization_posts_query(%Organization{id: id} = organization, viewer) do
    query = from(p in Post, where: p.organization_id == ^id)

    if match?(%User{}, viewer) and Organizations.publisher?(organization, viewer),
      do: query,
      else: where(query, [p], is_nil(p.frozen_at))
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

    from(p in RemotePost, where: p.id in ^ids, preload: [:remote_account, :screenshot])
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

  # `posts` in reading order: `thread_forest/1` walked depth-first, so every
  # reply directly follows the post it answers and a branch's answers stay
  # together instead of being interleaved by the clock.
  defp thread_order(posts) do
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

  @doc """
  The posts `user` liked, as a list a client can walk (`Vutuv.Keyset`).

  Ordered by the **post** id, not by when the like was made, because the id a
  Mastodon client hands back to ask for the next page is the status id and
  nothing else — a list ordered by one column and paged by another repeats
  rows and skips others. The website's saved/liked pages keep their
  newest-saved-first order and their search and sort controls
  (`liked_posts_page/2`); this is the same set of posts, walkable.
  """
  def liked_statuses(%User{} = user, opts \\ []),
    do: engaged_statuses(PostLike, user, opts)

  @doc "The posts `user` bookmarked, as a walkable list — see `liked_statuses/2`."
  def bookmarked_statuses(%User{} = user, opts \\ []),
    do: engaged_statuses(PostBookmark, user, opts)

  defp engaged_statuses(schema, %User{id: user_id} = user, opts) do
    from(p in Post,
      join: e in ^schema,
      on: e.post_id == p.id,
      where: e.user_id == ^user_id
    )
    |> scope_visible(user)
    |> Keyset.scope(opts)
    |> Repo.all()
    |> Keyset.restore(opts)
    |> preload_posts()
  end

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
        # LEFT for the same reason as the repost source: a bookmarked
        # organization post used to vanish from the saved list, and an empty
        # saved list looks exactly like an empty saved list.
        left_join: a in assoc(p, :user),
        as: :author,
        left_join: o in assoc(p, :organization),
        as: :engaged_organization,
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
    pattern = contains(term)

    # The page's name is searchable beside the member's: somebody looking for
    # what they saved from a company types the company. Without the third arm
    # an organization post could only be found by its body, which is the same
    # silent half-answer the inner join used to give.
    from([p, author: a, engaged_organization: o] in query,
      where:
        ilike(p.body, ^pattern) or name_ilike(a.first_name, a.last_name, ^pattern) or
          ilike(o.name, ^pattern)
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
  the row needs the author + permalink, not just the body) in one round
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
      # Both kinds of author (issue #1334): a quoted post may have been
      # published in an organization's name, and `path/1` matches on whichever
      # one is loaded. With `:user` alone the notifications page raised on the
      # first mention written by a page.
      |> Repo.preload([:user, :organization])
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

  # The whole page in one set of preload queries. `post_preloads/0` expands to
  # roughly twenty associations, so preloading post by post costs that many
  # queries per row — 50 rows of an organization's agent-format page came to a
  # four-figure query count for one request.
  defp preload_posts(posts) when is_list(posts),
    do: Repo.preload(posts, post_preloads(), force: true)

  defp post_preloads do
    # denials with group/denied_user: the author-facing audience display
    # names them (never shown to other viewers). The parent carries :images +
    # :tags too: the feed/profile thread nests it as a full post card (its own
    # action bar, images, tags), not just a one-line excerpt — which is also why
    # reply_ref goes two levels deep rather than one. A thread block's topmost
    # card is always a parent pulled in as context, and when that parent is
    # itself a reply the block opens mid-conversation; with nothing loaded for
    # its own banner it rendered as the post that STARTED the thread, so a
    # profile showed a stranger's answer to a third member as their opening
    # line. Level two carries only what that banner needs (the grandparent's
    # author, to name and link) — never the grandparent's own refs, which is
    # where an unbounded walk up the chain would start.
    [
      :images,
      # The other kind of author (issue #1334) — nil on a personal post, and the
      # one `Vutuv.Posts.author/1` names on an organization post. Deliberately
      # not `:acting_user`: who pressed publish is never rendered, so paying a
      # query for it on every page would buy nothing.
      :organization,
      # The auto link screenshot rendered beside a single-URL post (nil for
      # every other post); the card shows it only once `status: "ready"`.
      :screenshot,
      # The book/film review sidecar (nil for ordinary posts) — the card
      # renders it wherever the post renders, so it always travels along.
      :review,
      # The author, with the links they have PROVED are their own webpage
      # (issue #1246) — a link in the body pointing at one of them wears the
      # verified mark. One extra batched query per page, never one per card.
      user: verified_links_preload(),
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
          :images,
          :screenshot,
          :review,
          # Rendered as a full card, so its author's proven links come along
          # too (issue #1246) — same reason as the top-level `user` above.
          user: verified_links_preload(),
          tags: from(t in Tag, order_by: t.name),
          # The nested parent's own "Replying to …" line, local and remote: the
          # two states it can be in when it is a reply rather than a thread
          # starter. `parent_post: :user` is deliberately the author alone —
          # the grandparent is named and linked, never rendered.
          remote_reply_ref: [remote_post: :remote_account],
          reply_ref: [:parent_author, parent_post: :user]
        ]
      ]
    ]
  end

  # The post author's **verified** profile links (Vutuv.Profiles.Url), the
  # ones `VutuvWeb.Markdown.mark_verified_author_links/2` may mark in a body.
  # Scoped in the preload query rather than filtered afterwards, so a member
  # with fifty links still ships only the handful they proved — and ordered,
  # because an un-ordered multi-row preload comes back in whatever order
  # Postgres likes (id order is creation order, ids being UUID v7).
  defp verified_links_preload do
    [urls: from(u in Url, where: not is_nil(u.verified_at), order_by: u.id)]
  end

  @doc """
  The root-relative permalink path, e.g.
  `/stefan/posts/019748c8-1a2b-7c3d-8e4f-5a6b7c8d9e0f`. Lives under the
  author archive (`/:slug/posts`), whose year/month/day pages stay
  date-scoped index views. Requires `:user` / `:organization` to be preloaded.

  An organization post lives under the **slug** path (`/organizations/acme/posts/…`)
  rather than under the organization's opt-in root handle, even when it holds
  one. The handle route dispatches an organization only on the bare `/:slug`
  page (`VutuvWeb.Plug.UserResolveSlug`), everything deeper is member-only, and
  a permalink is the least forgiving URL there is: it is what a federated Note
  is identified by and what somebody pastes a year later. One shape that always
  works beats two that depend on whether a handle was claimed.
  """
  def path(%Post{id: id} = post), do: path(author(post), id)

  @doc """
  The same permalink, for a caller that holds the **author and the id** but no
  `%Post{}` — a notification row selected straight out of the database, or a
  federated Note whose `id` is its permanent identity.

  Those callers used to spell one of the two shapes out themselves, which is how
  a mention written by a page came to link into the member namespace
  (`/acme/posts/…`, a 404) on the reader's own notifications page.
  """
  def path(%Organization{slug: slug}, post_id), do: "/organizations/#{slug}/posts/#{post_id}"
  def path(%User{username: username}, post_id), do: "/#{username}/posts/#{post_id}"

  @doc """
  Where a post's author link goes: a member's profile at their handle, an
  organization's page at `Organizations.canonical_path/1`, which prefers its
  opt-in root handle over `/organizations/:slug`.

  The same rule `path/1` follows for the post itself, and for the same reason —
  it was written out at every surface that renders a post header, so the next
  kind of author would have to be remembered in each of them. It dispatches on
  what `author/1` hands back rather than on a pattern over the preloaded
  association: the association-shaped clause reads as a type check but behaves
  as a preload check, so a bare `%Post{}` out of a query drew a page's post as a
  nil member's.
  """
  def author_path(%Post{} = post), do: author_path(author(post))
  def author_path(%Organization{} = organization), do: Organizations.canonical_path(organization)
  def author_path(%User{username: username}), do: "/" <> username

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
      (ImageScans.released?(image.moderation) or ImageScans.privileged_viewer?(image, viewer))
  end

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

  # How many days an untouched draft is kept.
  defp draft_max_age_days,
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
      pattern = contains(term)

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
  # quoting. Delegates to the list head below for the dedupe.
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
  #
  # The count is NOT enforced here: the caller (`validate_tag_count/2`) turns a
  # sixth tag into a changeset error, so this returns everything that survived
  # normalisation and the dedupe.
  #
  # `Tags.canonical_tag_names/1` does that dedupe, and it dedupes by the tag a
  # name resolves to rather than by the spelling: an alternative name is one
  # writing of its topic (issue #1338), so "ROR, Ruby on Rails" is one tag —
  # which matters here because the cap is counted on what comes back, and being
  # refused a sixth tag for typing one tag twice is exactly what it must not do.
  defp parse_tag_values(values) when is_list(values) do
    values
    |> Enum.map(&Tag.normalize_value/1)
    |> Enum.reject(&(Tag.punctuation_only?(&1) or WebAddress.link_only?(&1)))
    |> Tags.canonical_tag_names()
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

  # Every post fans out the moment it is written, a photo still in the AI scan
  # included: the card arrives with a placecard where the picture will be, and
  # `{:post_images_settled, …}` swaps the real one in later. The post used to be
  # held back until the scan settled and the fan-out split in two because of it
  # (author now, followers on release), which is the shape issue #1104 shipped
  # and `moderation_hidden?/1` explains the retirement of.
  # An organization post has nobody to push to yet: the live fan-out rides the
  # member follower graph, and an organization cannot be followed until issue
  # #1336 gives it a reading side. It is not merely a no-op either — with a nil
  # author `follower_ids/1` would build `where: c.followee_id == ^nil`, which
  # Ecto **raises** on rather than silently matching nothing.
  defp broadcast_new_post(%Post{user_id: nil}), do: :ok

  defp broadcast_new_post(%Post{} = post) do
    broadcast_to_followers(post.user_id, new_post_event(post.id, post.user_id))
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

  # The counterpart to `broadcast_screenshot_ready/1`: the author removed a
  # post's auto link screenshot, so open feeds/profiles drop it from the card
  # with no reload. Fans out to the same recipients (author topic + followers'
  # feeds).
  defp broadcast_screenshot_removed(post_id) when is_binary(post_id) do
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
    reposter_id = repost.user_id || repost.organization_id

    event =
      {:new_repost, %{repost_id: repost.id, post_id: repost.post_id, reposter_id: reposter_id}}

    broadcast_to_followers(repost, event)
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

    existing =
      Repo.all(
        from(m in PostMention,
          where: m.post_id == ^post.id and not is_nil(m.user_id),
          select: m.user_id
        )
      )

    added = Enum.reject(wanted, &(&1.id in existing))

    drop_mentions(post, existing -- Enum.map(wanted, & &1.id))
    insert_mentions(post, added)
    Enum.each(added, &notify_mentioned(post, &1))
    sync_organization_mentions(post)
    :ok
  end

  # The same reconcile for the pages a body names by their root handle (issue
  # #1336). Its own pass rather than a widened one above: an organization has no
  # visibility to check (a page is public or it is not, which
  # `mentioned_organizations/1` already asked) and nobody to notify — the
  # mention shows up in the page's own activity list, which reads these rows.
  defp sync_organization_mentions(%Post{} = post) do
    wanted = post.body |> Mentions.mentioned_organizations() |> Enum.map(& &1.id)

    existing =
      Repo.all(
        from(m in PostMention,
          where: m.post_id == ^post.id and not is_nil(m.organization_id),
          select: m.organization_id
        )
      )

    drop_organization_mentions(post, existing -- wanted)
    insert_organization_mentions(post, wanted -- existing)
    :ok
  end

  defp drop_organization_mentions(_post, []), do: :ok

  defp drop_organization_mentions(%Post{} = post, organization_ids) do
    Repo.delete_all(
      from(m in PostMention,
        where: m.post_id == ^post.id and m.organization_id in ^organization_ids
      )
    )

    :ok
  end

  defp insert_organization_mentions(_post, []), do: :ok

  defp insert_organization_mentions(%Post{} = post, organization_ids) do
    now = NaiveDateTime.utc_now(:second)

    rows =
      Enum.map(
        organization_ids,
        &%{
          id: Vutuv.UUIDv7.generate(),
          post_id: post.id,
          organization_id: &1,
          inserted_at: now,
          updated_at: now
        }
      )

    Repo.insert_all(PostMention, rows, on_conflict: :nothing)
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

  # The actor is whoever the post is BY — the organization on an organization
  # post, never the member who pressed publish, which is exactly the split
  # `acting_user_id` exists to keep internal (issue #1334). `author/1` needs the
  # preload, and the mention sync runs on a freshly preloaded post.
  #
  # A block only guards the member case: a block is a relationship between two
  # people, and `blocked_between?/2` already answers false for a nil id.
  defp notify_mentioned(%Post{} = post, %User{} = mentioned) do
    unless Vutuv.Social.blocked_between?(mentioned.id, post.user_id) do
      Vutuv.Activity.notify_mention(mentioned.id, author(post), post.id)
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

  # Whose open feed has to drop this entry. A member's post reaches them and
  # their followers; an organization post reaches the people who follow the
  # **page** (issue #1336) — it never sat in the publishers' own feeds, so
  # there is nobody else to tell. Without this clause a nil author matched
  # neither head and deleting an organization post raised (issue #1334).
  defp deletion_recipients(%Post{organization_id: id}) when is_binary(id),
    do: organization_follower_ids(id)

  defp deletion_recipients(%Post{user_id: user_id}),
    do: [user_id | follower_ids(user_id)]

  defp organization_follower_ids(organization_id) do
    Repo.all(
      from(f in Follow,
        where: f.followee_organization_id == ^organization_id,
        select: f.follower_id
      )
    )
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

  defp broadcast_to_followers(%PostRepost{organization_id: page_id}, event)
       when is_binary(page_id) do
    # The people to tell are the PAGE's followers, and they hang off
    # `followee_organization_id`. Handing the page's id to the member query
    # would have compared `followee_id` with a nil reposter and RAISED - the
    # `where: x == ^nil` trap this milestone has paid for more than once.
    Enum.each(organization_follower_ids(page_id), &Vutuv.Activity.broadcast(&1, event))
  end

  defp broadcast_to_followers(%PostRepost{user_id: user_id}, event),
    do: broadcast_to_followers(user_id, event)

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
