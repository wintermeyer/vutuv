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
  import Vutuv.Identity.Query, only: [party_is: 2]

  import Vutuv.Moderation.Query,
    only: [account_hidden: 1, account_confirmed_row: 1, account_hidden_row: 1]

  import Vutuv.Organizations.Query, only: [organization_public_row: 1]
  import Vutuv.SearchText, only: [contains: 1, normalize_search: 1, name_ilike: 3]

  alias Ecto.Association.NotLoaded
  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.PostRepost, as: FediversePostRepost
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Keyset
  alias Vutuv.Mentions
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Moderation.Pixelation
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.Pages
  alias Vutuv.PostImageStore
  alias Vutuv.Posts.PhotoLicense
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
  alias Vutuv.Profiles.VerifiedLinks
  alias Vutuv.Repo
  alias Vutuv.Social.Follow
  alias Vutuv.Social.PastFollow
  alias Vutuv.Tags
  alias Vutuv.Tags.Tag
  alias Vutuv.Translations
  alias Vutuv.Uploads.Crop
  alias Vutuv.UUIDv7

  @default_feed_limit 20

  # How many resharers a feed entry carries. The "Reposted by" banner draws this
  # many faces and then a `+N` chip, so loading more would be rows fetched to be
  # thrown away — and on a post of the reader's own, where the roster is no
  # longer bounded by their follow set, a widely reshared post would fetch
  # thousands of them to draw five. The tail is counted in SQL instead
  # (`reposters_total`), so the chip's figure stays honest.
  @roster_cap 5

  @doc """
  How many resharers a feed entry's roster holds — the cap the banner's avatar
  stack draws up to (`VutuvWeb.PostComponents`). One number, or the query would
  fetch fewer faces than the stack wants to show.
  """
  def reposter_roster_cap, do: @roster_cap
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
          told = broadcast_new_post(post)
          broadcast_reply(parent, post, told)
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
  Whether this post is in a state that accepts answers at all — the half of the
  reply rule that depends on the post alone, with nobody asking yet.

  A post published in a page's name is answerable like any other (issue #1336):
  it was refused outright while a page had no reading side, since every
  consequence of a reply was member-shaped and the answer would have reached
  nobody, and the page's activity list is now what receives it. What this asks is
  the one thing `visible_to?/2` deliberately does **not**: whether the page
  itself is publicly visible. Page visibility lives in the queries (see
  `moderation_hidden?/1`), which is right for every list, but the reply page
  renders the parent card from an id in the URL — so without this a guessed id
  would confirm and quote the post of a pending or frozen page.

  Public because it is the first arm of `answerable_by?/2`, which the reply
  **page** asks — and it is a fair question on its own, about the post rather
  than about anybody wanting to answer it.
  """
  def answerable?(%Post{organization_id: nil}), do: true

  def answerable?(%Post{organization_id: id}) when is_binary(id) do
    # Read fresh by id, deliberately **not** through the preloaded
    # `:organization` — for the same reason `parent_restricted_now?/1` re-queries
    # the denials: the reply LiveView holds the parent struct from mount, and the
    # page may have been frozen or sent back to `pending` since. Matching on the
    # preloaded association would also read as a type check while behaving as a
    # preload check, which is how a page's post once fell into the member branch.
    case Organizations.get_organization(id) do
      nil -> false
      page -> Organizations.public_visible?(page)
    end
  end

  @doc """
  Whether `user` may open a composer answering `post` — the compose page's half
  of `check_reply_allowed/2` below, which is the same rule minus the block.

  The block is deliberately left out: quiet blocking has to let the blocked
  member reach the composer and be refused on submit, or the block leaks. That
  one difference is the whole reason the page cannot simply call the gate, and
  it is why the rule was written out a second time in
  `VutuvWeb.PostLive.Reply.mount/3` — where nothing tied it to the gate, so a
  fifth arm added here would have silently missed the page (issue #1797).

  `restricted?/1` here rather than the gate's fresh re-read: the page is a cheap
  "may I show you this at all", and the submit path re-asks anyway.
  """
  def answerable_by?(%Post{} = post, user) do
    answerable?(post) and visible_to?(post, user) and not restricted?(post)
  end

  defp check_reply_allowed(%User{} = author, %Post{} = parent) do
    cond do
      not answerable?(parent) -> {:error, :not_visible}
      not visible_to?(parent, author) -> {:error, :not_visible}
      # Query restriction fresh from the DB, not the (possibly stale) preloaded
      # denials: the reply LiveView holds the parent struct from mount, and the
      # author may have restricted the post after it was loaded.
      parent_restricted_now?(parent) -> {:error, :restricted}
      # A block between author and parent author refuses the reply with the
      # same opaque :restricted the disabled reply button already explains. A
      # block is between two members, so a page's post has none: `blocked?/2`
      # reads `parent.user_id`, which is NULL there, and `blocked_between?/2`
      # answers false for a nil side rather than raising.
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
    # either — by the chip row **or** by the body's hashtags: find-or-create runs
    # only on a set that can be kept, and `put_body_hashtags/3` is told the same.
    keepable? = not too_many_tags?(tag_values)
    tag_ids = if keepable?, do: tag_ids_for(tag_values), else: []

    changeset =
      post_or_struct
      |> Post.changeset(post_params(attrs))
      |> Ecto.Changeset.put_assoc(:denials, Enum.map(denials, &struct(PostDenial, &1)))
      |> Ecto.Changeset.put_assoc(:post_tags, Enum.map(tag_ids, &%PostTag{tag_id: &1}))
      |> put_body_hashtags(tag_ids, keepable?)
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
  # drops the filing), and never a tag the composer's field already filed: that
  # one is a chip on the card, and one filing per (post, tag) is all the tag
  # page can use.
  #
  # `mint?` (true unless the post is already doomed by its tag count, see
  # `build_changeset/4`) lets a hashtag naming a topic nobody here has written
  # about yet mint it — writing `#Eisenach` in a sentence declares the tag as plainly
  # as typing it into the tag field does, and the chip row is capped at five
  # while a body is not. The hashtags go in **as written**
  # (`Mentions.written_hashtags/1`, not `hashtags/1`): a minted tag keeps the
  # spelling of whoever names it first, and lowercasing here would name it for
  # everybody after.
  defp put_body_hashtags(changeset, field_tag_ids, mint?) do
    hashtag_ids =
      changeset
      |> Ecto.Changeset.get_field(:body)
      |> to_string()
      |> Mentions.written_hashtags()
      |> Tags.tag_ids_for_hashtags(create: mint?)
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
      # Whichever of the two authors the parent has (issue #1334): the columns
      # are read as a pair everywhere, and the page's own activity list is
      # derived from `parent_organization_id` the way a member's reply
      # notification is derived from `parent_author_id`.
      parent_author_id: parent.user_id,
      parent_organization_id: parent.organization_id,
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

  @doc """
  Who performed an engagement — a like, a repost or a bookmark — as the world
  sees it: the `%User{}` who pressed it, or the `%Organization{}` it was done in
  the name of (issue #1336).

  The twin of `author/1`, and it exists for the same reason: these three rows
  carry the same nullable pair (`user_id` beside `organization_id`), so reading
  `like.user` is `nil` the moment a page likes something. That is not a visible
  error anywhere — it is a `nil` handed onward — and it killed the nightly
  report inside its own `handle_info` the first time a page liked a post, which
  loses the day's mail with nothing in the log to say why.

  Like `author/1`, this matches on the **column** and falls back to a lookup
  when the association was not preloaded, so a caller that forgot the preload
  gets an answer rather than an `%Ecto.Association.NotLoaded{}`.
  """
  def actor(%{organization_id: nil, user: %NotLoaded{}, user_id: user_id}),
    do: Repo.get(User, user_id)

  def actor(%{organization_id: nil} = row), do: row.user

  def actor(%{organization: %NotLoaded{}, organization_id: organization_id}),
    do: Repo.get(Organization, organization_id)

  def actor(row), do: row.organization

  @doc """
  The text a post carries, whichever kind of post it is: a member's Markdown
  `body`, a cached remote post's or a remote reply's plain `content_text`.
  Nil where nothing was written (a photograph and no words).

  The companion of `author/1` and `path/1`, and here for the same reason: the
  three kinds keep their text in two differently named columns, so every caller
  that reached for one of them by hand was a place the next kind would have to
  be remembered again. `Vutuv.Translations.source_text/1` and
  `VutuvWeb.PostTeaser` both read it from here.
  """
  def text(%Post{body: body}), do: body
  def text(%RemotePost{content_text: text}), do: text
  def text(%Note{content_text: text}), do: text

  @doc """
  When a post was written, whichever kind of post it is.

  The third of the same family as `text/1` and `path/1`: three kinds, three
  differently named columns, and every caller that reached for one by hand was a
  place the next kind would have to be remembered again. A member's post is
  dated by `inserted_at`, a cached remote post by the `published_at` its origin
  claims, a remote reply by when it reached us — the last because a reply's own
  origin timestamp is not something this installation saw.
  """
  def written_at(%Post{inserted_at: at}), do: at
  def written_at(%RemotePost{published_at: at}), do: at
  def written_at(%Note{received_at: at}), do: at

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
  Whether a post **arriving live** reaches `viewer`'s feed — the in-memory twin
  of what a feed source's query would have decided about it.

  The feed answers that question twice: in SQL when a page is fetched, and here
  when a post arrives over PubSub. While the two disagreed, the pill counted
  posts the next read then dropped — a muted member's, or one in a language the
  reader filters out — so pressing it showed fewer posts than it promised, or
  none. Four gates, in the order the query asks them:

    * the author is not blocked, either way (`scope_visible/2` never checks
      blocks, which is why the caller used to ask this one separately),
    * the post's own audience lets this reader in (`visible_to?/2`),
    * the reader has not muted the author (`followees_of/1`'s `muted == false`),
    * and it is in a language they chose (`language_scope/2`).

  The tab filter is a **different** question and stays with the caller: it
  decides which of two lists a post belongs in, not whether it reaches the
  reader at all, and an arrival for the other tab lights that tab's dot rather
  than being dropped (issue #1503).
  """
  def reaches_feed?(%Post{} = post, %User{} = viewer) do
    not Vutuv.Social.blocked_between?(viewer.id, post.user_id) and
      visible_to?(post, viewer) and not muted_author?(post, viewer) and
      language_allowed?(post, viewer)
  end

  defp muted_author?(%Post{user_id: author_id}, %User{id: viewer_id})
       when is_binary(author_id) do
    Repo.exists?(
      from(f in Follow,
        where: f.follower_id == ^viewer_id and f.followee_id == ^author_id and f.muted
      )
    )
  end

  defp muted_author?(_post, _viewer), do: false

  # The `language_scope/2` clause, asked of one post: an undeclared language
  # never hides (the same NOT-IN/NULL lesson), and no filter means no question.
  defp language_allowed?(%Post{language: language}, %User{} = viewer) do
    case feed_language_filter(viewer) do
      nil -> true
      chosen -> is_nil(language) or language in chosen
    end
  end

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

  # A page as the VIEWER (issue #1336, mirroring `visible_to?/2`'s own
  # Organization clauses): it is not a member, so no denial can name it and it
  # sees exactly what an anonymous reader sees, plus its own posts while
  # moderation holds them — the way an author sees theirs.
  def scope_visible(query, %Organization{id: organization_id} = viewer) do
    from(p in query,
      where:
        p.organization_id == ^organization_id or
          fragment("NOT EXISTS (SELECT 1 FROM post_denials d WHERE d.post_id = ?)", p.id)
    )
    |> scope_unfrozen(viewer)
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
        %User{id: viewer_id} ->
          dynamic([p], p.user_id == ^viewer_id or ^passes)

        %Organization{id: organization_id} ->
          dynamic([p], p.organization_id == ^organization_id or ^passes)

        nil ->
          passes
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
      {:ok, %PostLike{} = like} ->
        Vutuv.Activity.notify_like(post.user_id, page, post.id, like.id)
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
      {:ok, %PostLike{} = like} ->
        # A fresh like is news for the author; the idempotent repeat is not.
        # Self-likes never reach here (`like_post/2` rejects them upstream).
        Vutuv.Activity.notify_like(post.user_id, user, post.id, like.id)
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
            broadcast_new_repost(repost, post)

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
        broadcast_new_repost(repost, post)

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

  @doc """
  The post a repost row named, or `nil` — the lookup behind a reshare's own id.

  A reshare is a status in its own right to a Mastodon client
  (`Vutuv.MastodonApi.Presenter.reshared/2` renders it as `repost-<uuid>`), and
  the id it hands back has to resolve to something. What it resolves to is the
  post underneath: acting on a reshare means acting on the post, which is what
  Mastodon does too. Unscoped by design — every caller re-asks its own
  visibility question of the post it gets.
  """
  def get_reposted_post(id) do
    with %PostRepost{post_id: post_id} <- get_post_repost(id), do: get_post(post_id)
  end

  @doc """
  The repost **row** an id names, or `nil` — the act rather than what it passed
  on, for a caller that has to know *whose* reshare it is before undoing one
  (`VutuvWeb.MastodonApi.Statuses`). Unscoped like its twin above: the caller
  compares the row's owner with the identity it is acting as.
  """
  def get_post_repost(id), do: UUIDv7.with_cast(id, &Repo.get(PostRepost, &1))

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
  still count, they simply have no face to show. A **page's** like (issue
  #1410) is listed like a member's — a `%Organization{}` among the users —
  behind its own gate (`organization_public_row/1`), so a frozen page loses
  its face the same way a frozen member does.
  """
  def post_likers(post_id, opts \\ []) when is_binary(post_id) do
    # Matches `<.avatar_stack>`'s cap, so the row never queries rows it would
    # only fold into `+N` — and the agent formats name exactly the same people
    # the page does.
    limit = Keyword.get(opts, :limit, @likers_shown)

    from(l in PostLike,
      left_join: u in User,
      on: u.id == l.user_id,
      left_join: o in Organization,
      on: o.id == l.organization_id,
      where: l.post_id == ^post_id,
      # Each actor kind passes its own gate: on a LEFT-joined missing users
      # row `is_nil(u.email_confirmed?)` is TRUE, so an unscoped member gate
      # would wave every page row through, frozen ones included (the #1408
      # shape).
      where:
        (not is_nil(l.user_id) and account_confirmed_row(u) and not account_hidden_row(u)) or
          (not is_nil(l.organization_id) and organization_public_row(o)),
      # UUID v7: id order is creation order, so this is newest liker first.
      order_by: [desc: l.id],
      limit: ^limit,
      select: {u, o}
    )
    |> scope_attributed(Keyword.get(opts, :include_hidden?, false))
    |> Repo.all()
    |> Enum.map(fn {user, page} -> page || user end)
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

    # Scoped per actor kind, like every gate on the nullable pair: attribution
    # is a member's preference, and a page's like (issue #1410) has no such
    # column — its NULL would resolve to the installation default and could
    # silently drop every page. The members-only queries below never produce a
    # page row, so the second arm is structurally inert there.
    from([l, u] in query,
      where:
        (not is_nil(l.user_id) and
           coalesce(field(u, :like_attribution?), type(^default, :boolean)) == true) or
          not is_nil(l.organization_id)
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

  # A save within this many seconds of writing is not an edit: the composer and
  # the pipeline both touch `updated_at` right after an insert.
  @edit_mark_slack 60

  @doc """
  Whether `post` has been changed since it was written.

  vutuv stores no edit timestamp, so the rule is `updated_at` having moved away
  from `inserted_at`. It lives here rather than at its two readers — the post
  card's "edited" hint and the Mastodon adapter's `edited_at` — because those
  two must not be able to disagree about a post, and two copies of one
  threshold is exactly the arrangement that drifts.
  """
  def edited?(%Post{inserted_at: created, updated_at: changed}),
    do: NaiveDateTime.diff(changed, created) > @edit_mark_slack

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
  # rather than false — `party_is/2` spells the pair predicate once.
  defp engaged_by(party), do: dynamic([e], party_is(e, party))

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
  def post_engagement_map([], _viewer), do: %{}

  def post_engagement_map(post_ids, viewer) do
    from(p in Post, where: p.id in ^post_ids)
    |> engagement_select(engagement_viewer_id(viewer))
    |> Repo.all()
    |> Map.new(fn engagement -> {engagement.id, engagement} end)
  end

  @doc """
  Who each of `post_ids` names with an `@handle`, as
  `%{post_id => [%User{} | %Organization{}]}`.

  One batched read for a whole page, the way `post_engagement_map/2` reads the
  action bar's figures — a mention list built per post would be a round trip per
  card. (The `preload` costs three round trips, not one: the rows, then one per
  association. Three per page, never per post, is the point.) The rows come from `post_mentions`, the resolved index `Vutuv.Posts`
  reconciles on every save, so this asks the same table the `"mention"`
  notification kind reads and cannot drift from what was actually notified.

  Both author kinds ride one row (issue #1336, CHECK-enforced to exactly one),
  so a page is listed here as readily as a member.
  """
  def mention_map([]), do: %{}

  def mention_map(post_ids) when is_list(post_ids) do
    from(m in PostMention,
      where: m.post_id in ^post_ids,
      order_by: m.id,
      preload: [:user, :organization]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.post_id, &(&1.user || &1.organization))
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
  any. The one raw read of the `feed_languages` column — its three consumers,
  the hide filter below, the translate mode's "is this post foreign?"
  test (`VutuvWeb.Live.PostTranslations`) and the settings card's ticked
  chips, interpret an empty choice differently BY DESIGN: hide mode with no
  chips hides nothing (`feed_language_filter/1` answers nil), translate mode
  with no chips treats only the UI locale as the member's own, and the card
  ticks nothing at all while offering a suggestion beside it
  (`suggested_feed_languages/1`).
  """
  def chosen_feed_languages(%User{feed_languages: chosen}), do: chosen || []

  @doc """
  The languages the Feed-languages card puts in the open (issue #1537): what
  this account already says the member reads — their interface language plus the
  language skills on their profile.

  A **suggestion**, not a choice, and the card is careful about the difference:
  it decides which chips are visible without a disclosure and ticks nothing. A
  pre-ticked suggestion would be a filter nobody chose, and it would ride along
  the next save of the neighbouring "posts in other languages" select.

  The profile half is read here rather than taken from a preload, so the answer
  cannot depend on whether a call site remembered one. The order is not part of
  the answer — the card lays its chips out by localized label — so this does not
  pay for `Vutuv.Profiles.Language.ordered/1`.
  """
  def suggested_feed_languages(%User{} = user) do
    Enum.uniq([interface_language(user) | profile_language_skills(user)])
  end

  # `cast_language/1` on both, or a third-party installation running a regioned
  # locale ("pt-BR") suggests a code the chips do not carry and the card opens
  # with nothing in the open at all.
  defp interface_language(%User{locale: locale}) do
    Translations.cast_language(locale) ||
      Translations.cast_language(Gettext.get_locale(VutuvWeb.Gettext))
  end

  defp profile_language_skills(%User{id: id}) do
    from(l in Vutuv.Profiles.Language, where: l.user_id == ^id, select: l.language_code)
    |> Repo.all()
    |> Enum.flat_map(&List.wrap(Translations.cast_language(&1)))
  end

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
  `:vutuv` or `:fediverse`; see `feed_sources/3`.
  """
  def feed_page(%User{} = viewer, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_feed_limit)
    cursor = Keyword.get(opts, :cursor)
    filter = Keyword.get(opts, :filter, :all)

    page = Vutuv.FeedPage.paginate(feed_sources(viewer, filter), limit, cursor)

    %{page | entries: decorate_feed_entries(page.entries, viewer, threads: true)}
  end

  @doc """
  How many feed entries reached `viewer` on each day of a window — the numbers
  the feed calendar's heatmap shades (issue: the vertical time controls).

  Counted through **`feed_sources/3`**, the same nine sources a page is built
  from, so a day the heatmap calls busy is a day the timeline will actually
  have something on. A separate hand-written count query would be a second
  definition of "what is in my feed" and would drift from the first one.

  Asked in the **`:marks`** shape, which is the same rows with what a card needs
  left out. That is not a detail — building a month of a fediverse-heavy feed as
  preloaded structs to produce thirty numbers was most of what unfolding the
  calendar cost — and it is not a filter either: same queries, same window, same
  counts. The figures are in `docs/architecture/posts-and-feed.md`; how much
  each source can leave out is up to the source, and `Vutuv.Fediverse` says.

  Counts **arrivals, not cards**. The rendered timeline collapses several posts
  of one thread into a single entry, so a day counted at 306 here draws 271
  cards (measured, 2026-08-18); the shading is "how much reached you", which is
  the question a heatmap answers and the same one GitHub's contribution graph
  answers. The relationship only ever goes one way — collapsing reduces — so
  the count is an upper bound on cards and never undersells a day.

  Returns `%{Date.t() => pos_integer}` in the **caller's** current viewer clock
  (`Vutuv.ViewerClock`), because the calendar draws the reader's calendar days,
  not UTC ones. Days with nothing are absent rather than zero.

  Bounded by `cap`: a month of a busy feed is thousands of rows and this runs
  on every month the reader pages to. Past the cap the counts are a **lower
  bound**, which the caller is told about (`capped?`) rather than left to
  believe a quiet-looking month. The entries are counted, never decorated: the
  heatmap needs numbers, and `decorate_feed_entries/3` is the expensive half.
  """
  def feed_activity_by_day(%User{} = viewer, %Date{} = from, %Date{} = to, opts \\ []) do
    filter = Keyword.get(opts, :filter, :all)
    cap = Keyword.get(opts, :cap, 3_000)

    {first, _} = Vutuv.ViewerClock.day_window(from)
    {_, last} = Vutuv.ViewerClock.day_window(to)
    cursor = %{at: last, ids: [], since: first}

    entries =
      Enum.map(feed_sources(viewer, filter, :marks), fn fetch -> fetch.(cap, cursor) end)

    # Truncation is a per-SOURCE fact, not a fact about their union: the cap is
    # each source's `LIMIT`, so nine sources of 400 rows each make 3,600
    # entries without a single one having been cut short. Testing the union
    # against the cap cried "incomplete" on every ordinary busy month.
    capped? = Enum.any?(entries, &(length(&1) >= cap))

    counts =
      entries
      |> Enum.concat()
      |> Enum.uniq_by(& &1.id)
      |> Enum.frequencies_by(&Vutuv.ViewerClock.date(&1.at))
      |> Map.filter(fn {date, _n} ->
        Date.compare(date, from) != :lt and Date.compare(date, to) != :gt
      end)

    %{counts: counts, capped?: capped?}
  end

  @doc """
  Whether `viewer`'s feed reaches back past the start of `date`'s month — what
  decides when the calendar's back arrows stop.

  One row is all it takes to answer, so this asks for exactly one through the
  **same nine sources** a page is built from. A hand-written "oldest post"
  query would be a second definition of what is in a feed, and the arrows would
  eventually disagree with the timeline they scroll.

  Undecorated on purpose, in the `:marks` shape: the question is whether
  anything exists, and neither `decorate_feed_entries/3` nor a card's preloads
  help answer it.
  """
  def feed_reaches_before_month?(%User{} = viewer, %Date{} = date, opts \\ []) do
    filter = Keyword.get(opts, :filter, :all)

    {month_start, _} = date |> Date.beginning_of_month() |> Vutuv.ViewerClock.day_window()
    before = NaiveDateTime.add(month_start, -1, :second)

    page =
      Vutuv.FeedPage.paginate(feed_sources(viewer, filter, :marks), 1, %{at: before, ids: []})

    page.entries != []
  end

  # `shape` is what the caller does with the rows: `:entries` carries everything
  # a card draws, `:marks` only the `id` and the `at` a counter needs
  # (`Vutuv.FeedPage.mark/1`). A source that has no cheaper shape ignores the
  # argument and hands back the richer one, which carries both keys anyway — so
  # the two are interchangeable and no source can be counted under a different
  # definition than it is rendered under.
  #
  # Only the two fediverse sources below act on it, because they are the two
  # that carry the volume: a reader who follows a few hundred accounts out there
  # meets several thousand of their posts and boosts in a month and a couple of
  # hundred of everything else. What each saves differs and the owning module
  # says so — see `docs/architecture/posts-and-feed.md`.
  defp feed_sources(viewer, filter, shape \\ :entries)

  # `:own` is a different axis from the three below and belongs to the feed
  # calendar, not to the source band: the band asks *which network*, this asks
  # *whose posts*. It is never written to `users.feed_source` (only the band's
  # checkboxes do that, and they cannot produce it), so a reader who picks "My
  # posts" and comes back tomorrow gets their ordinary feed.
  #
  # It is also what the calendar's "My posts" heatmap counts, so the shading and
  # the timeline under it are one definition rather than two. One local source,
  # so there is no cheaper shape to offer.
  defp feed_sources(viewer, :own, _shape), do: [&feed_own_post_items(viewer, &1, &2)]

  defp feed_sources(viewer, :vutuv, shape) do
    [
      &feed_post_items(viewer, &1, &2),
      &feed_organization_post_items(viewer, &1, &2),
      &feed_repost_items(viewer, &1, &2),
      &feed_tag_items(viewer, &1, &2),
      &feed_reply_to_me_items(viewer, &1, &2),
      &feed_repost_of_mine_items(viewer, &1, &2),
      &Vutuv.Fediverse.feed_remote_boosts(viewer, &1, &2, only: :local, shape: shape),
      &Vutuv.Fediverse.feed_remote_reposts(viewer, &1, &2),
      &Vutuv.Fediverse.feed_remote_reply_reposts(viewer, &1, &2)
    ]
  end

  defp feed_sources(viewer, :fediverse, shape) do
    [
      &Vutuv.Fediverse.feed_remote_posts(viewer, &1, &2, shape: shape),
      &Vutuv.Fediverse.feed_remote_boosts(viewer, &1, &2, only: :remote, shape: shape)
    ]
  end

  defp feed_sources(viewer, _all, shape) do
    [
      &feed_post_items(viewer, &1, &2),
      # What the organizations the viewer follows have published (issue #1336).
      &feed_organization_post_items(viewer, &1, &2),
      &feed_repost_items(viewer, &1, &2),
      &feed_tag_items(viewer, &1, &2),
      # What happened to the reader's **own** posts, whoever did it — the two
      # sources that are not about a follow at all.
      &feed_reply_to_me_items(viewer, &1, &2),
      &feed_repost_of_mine_items(viewer, &1, &2),
      &Vutuv.Fediverse.feed_remote_posts(viewer, &1, &2, shape: shape),
      # Fifth: what people the viewer follows *here* have reshared from
      # another network (issue #1166) — the one way a member who follows
      # nobody out there meets that content at all.
      &Vutuv.Fediverse.feed_remote_reposts(viewer, &1, &2),
      # Sixth: what the accounts the viewer follows out there have
      # re-shared (issue #1167) — a large part of what any account
      # contributes, and invisible here until now.
      &Vutuv.Fediverse.feed_remote_boosts(viewer, &1, &2, shape: shape),
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
  How the member arranged the feed's filter band: which blocks in which order,
  which are collapsed to their heading, which they removed altogether.

  One map on the member rather than three columns, because it is one decision —
  "my sidebar looks like this" — that the panel writes as a whole. Unknown block
  names are dropped on read and unlisted ones appended, so a block that ships
  later simply turns up at the end for everybody who arranged the band before it
  existed, and a retired one leaves no orphan behind.

  `collapsed` is the shipped default: which cards a member who has never touched
  the rail starts with folded to their heading. It applies **only** in the
  absence of a stored arrangement — a member who has one keeps it whole,
  including the cards they deliberately left open, and a block that ships later
  joins their rail unfolded, because a new card nobody can see is a new card
  nobody will find.
  """
  def feed_rail(user, blocks, collapsed \\ [])

  def feed_rail(%User{feed_rail: rail}, blocks, _collapsed) when is_map(rail) do
    known = Enum.map(blocks, &to_string/1)
    listed = rail |> Map.get("order", []) |> Enum.filter(&(&1 in known))

    %{
      order: listed ++ Enum.reject(known, &(&1 in listed)),
      collapsed: rail |> Map.get("collapsed", []) |> Enum.filter(&(&1 in known)),
      removed: rail |> Map.get("removed", []) |> Enum.filter(&(&1 in known))
    }
  end

  def feed_rail(%User{}, blocks, collapsed) do
    known = Enum.map(blocks, &to_string/1)

    %{
      order: known,
      collapsed: collapsed |> Enum.map(&to_string/1) |> Enum.filter(&(&1 in known)),
      removed: []
    }
  end

  @doc """
  Apply a drag to the arrangement: `moved` is the order the reader dropped the
  blocks into, and it lists only the ones that were on screen.

  That is the whole reason this is not `%{rail | order: moved}`. Half the rail
  is conditional — the "not read yet" card is there only while something is
  waiting, "Tags you follow" only once a tag is followed — so a block that is
  simply not showing today would be dropped from the stored order by a plain
  overwrite and re-appended at the end tomorrow, silently rearranging the rail
  from a drag that never touched it. So the stored order keeps its shape and
  only the positions that were visible take the new sequence.
  """
  def rearrange_feed_rail(%{order: order} = rail, moved) when is_list(moved) do
    # The sequence arrives from the browser, so it is filtered and de-duplicated
    # rather than trusted: a repeated name would otherwise consume two slots and
    # run the list short.
    moved = moved |> Enum.filter(&(&1 in order)) |> Enum.uniq()

    {next, _rest} =
      Enum.map_reduce(order, moved, fn key, rest ->
        case {key in moved, rest} do
          {true, [head | tail]} -> {head, tail}
          _ -> {key, rest}
        end
      end)

    %{rail | order: next}
  end

  @doc """
  Store the band's arrangement — takes what `feed_rail/2` answers.

  A narrow `update_all` for the same reason `remember_feed_filter/3` uses one:
  the socket's `%User{}` was loaded at mount and writing the whole struct back
  would undo whatever else changed meanwhile.
  """
  def save_feed_rail(%User{} = user, %{order: order, collapsed: collapsed, removed: removed}) do
    rail = %{"order" => order, "collapsed" => collapsed, "removed" => removed}

    {1, nil} = Repo.update_all(from(u in User, where: u.id == ^user.id), set: [feed_rail: rail])

    {:ok, rail}
  end

  @doc """
  Remembers `filter` as `user`'s feed tab for the next visit, `leaving` being
  the tab they are coming from.

  A narrow `update_all` rather than a changeset: a socket's `%User{}` was
  loaded at mount and can be hours old by the time a tab is clicked, so writing
  the whole struct back would undo whatever else changed meanwhile — from
  another device, or from a settings page in the next tab. For the same reason
  it does not first ask whether the stored value differs; that question cannot
  be answered from a struct that may be stale. Last click wins, which is what a
  "last chosen" value means.

  `feed_source_at` is the exception, and `leaving` is why it is an argument
  rather than a comment at the call site: it dates the reader's *move*, and a
  press on the source they are already on moves nobody. **Nothing reads that
  column today.** Its reader was the coral dot on the tab you were not on, which
  went with the tabs themselves; the column and this argument are still here
  because dropping a column takes the two deploys of expand/contract, and this
  is the write side that has to go first.
  """
  def remember_feed_filter(%User{} = user, filter, leaving) do
    stored = if filter in [:vutuv, :fediverse], do: to_string(filter)

    set =
      if leaving == filter,
        do: [feed_source: stored],
        else: [feed_source: stored, feed_source_at: NaiveDateTime.utc_now(:second)]

    {1, nil} = Repo.update_all(from(u in User, where: u.id == ^user.id), set: set)

    :ok
  end

  @doc """
  Whether the feed tab `filter` shows `entry` — the in-memory twin of the source
  split in `feed_sources/3`, for the entries that arrive live over PubSub rather
  than through a query.

  The split is not "which kind of post" alone: an entry carrying remote content
  is a **vutuv** entry as soon as a member here passed it on (`reposted_by`),
  whoever that was. See `feed_sources/3` for why.
  """
  def feed_filter_accepts?(:vutuv, entry),
    do: not remote_feed_entry?(entry) or reshared_here?(entry)

  def feed_filter_accepts?(:fediverse, entry),
    do: remote_feed_entry?(entry) and not reshared_here?(entry)

  # `:own` is deliberately not answered here and falls through to `true`: whose
  # post it is cannot be read off the entry alone, and the caller that knows the
  # viewer decides it instead (`VutuvWeb.PostLive.Feed`'s `view_accepts?/3`).
  def feed_filter_accepts?(_all, _entry), do: true

  # Whether a member here put this entry in front of the reader. `boosted_by` is
  # deliberately not it: that is an account out there passing something on, and
  # nobody here did anything.
  defp reshared_here?(entry), do: entry[:reposted_by] != nil

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
  Whether the source `source` holds anything for `viewer` stamped at or after
  `since` — the boolean half of `newest_source_entry/3` below.

  It skips that one's decorate pass, and `Enum.any?/2` stops at the first
  source that answers rather than asking all of them.
  """
  def feed_source_since?(%User{} = viewer, source, %NaiveDateTime{} = since)
      when source in [:vutuv, :fediverse] do
    viewer
    |> feed_sources(source)
    |> Enum.any?(&(newest_row(&1, since) != []))
  end

  @doc """
  The newest entry the tab `source` holds for `viewer` stamped at or after
  `since`, decorated for rendering — or nil. What the feed asks before dotting
  a tab it is not looking at (issue #1503), and quoting its first words there.

  Same shape as `fediverse_feed_available?/1` one question narrower, and for
  the same reason: **only the reader's own sources know whether a post reaches
  them**. A mute, a follow still merely requested, an audience narrower than
  public, a language they filter out and the resharer's own standing all decide
  per member, so the write that triggered this cannot fan out an answer — it
  can only say "something landed, go and look". Each source is asked for its
  newest row and the newest of those wins.

  It answers "this is what sits at the top of that tab, and it is at least as
  new as what just landed", not "that exact post reached you". The two come
  apart only when a server delivers a post published well before now: then the
  entry this finds is the tab's newest rather than the arrival. That is also
  the entry the reader lands on when they follow the dot, so it is the
  conservative side to err on — the side it must never err on is a post the
  reader may not see, which is why the sources answer rather than the fan-out.

  Costs one decorate pass on a single row, so quoting the arrival is no more
  work than the boolean this replaced plus that pass.
  """
  def newest_source_entry(%User{} = viewer, source, %NaiveDateTime{} = since)
      when source in [:vutuv, :fediverse] do
    viewer
    |> feed_sources(source)
    |> Enum.flat_map(&newest_row(&1, since))
    |> case do
      [] ->
        nil

      candidates ->
        # The sources are asked one row each, so the newest of those rows is the
        # tab's newest — and it is the one the reader would land on.
        candidates
        |> Enum.max_by(& &1.at, NaiveDateTime)
        |> List.wrap()
        |> decorate_feed_entries(viewer)
        |> List.first()
    end
  end

  # One source's newest row, kept only if it is at least as new as `since`.
  defp newest_row(fetch, since) do
    case fetch.(1, nil) do
      [entry | _] -> if NaiveDateTime.compare(entry.at, since) != :lt, do: [entry], else: []
      [] -> []
    end
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
  # `threads: true` adds the two reads only a surface that draws the nested
  # conversation can use (`<.post_thread_entry>`): the replies from other
  # networks under this page's posts, and the cached posts they answer. The
  # organization feed renders flat `<.post_card>`s and the tab ticker quotes a
  # single row, so both would pay for something they cannot show.
  defp decorate_feed_entries(entries, viewer, opts \\ []) do
    {remote, local} = Enum.split_with(entries, &remote_feed_entry?/1)

    local =
      local
      |> hydrate_posts()
      |> collapse_threads()
      |> collapse_reposts()
      |> attach_reposters(viewer)
      |> attach_remote_thread(viewer, remote, Keyword.get(opts, :threads, false))

    Vutuv.FeedPage.sort_entries(local ++ decorate_remote(remote, viewer))
  end

  defp attach_remote_thread(local, _viewer, _remote, false), do: local

  defp attach_remote_thread(local, viewer, remote, true) do
    local
    |> attach_thread_notes(viewer, standalone_note_ids(remote))
    |> attach_remote_parents(viewer, standalone_remote_post_ids(remote))
  end

  # The cached post a member's answer answers (issue #1165), so the feed can
  # draw it above them instead of the bare "Replying to @user@host" line an
  # answer with nothing to read above it used to be.
  #
  # It rides `remote_reply_ref`, already preloaded with its account
  # (`post_preloads/0`), so this costs no lookup — only the same three batch
  # reads a remote card needs anywhere (its pictures, the reader's marks, the
  # reader's follow), run once for the page. `taken` keeps a post that already
  # has a card of its own from getting a second one, exactly as for a reply.
  defp attach_remote_parents(entries, viewer, taken) do
    taken = MapSet.new(taken)

    parents =
      for entry <- entries,
          post <- thread_posts(entry),
          %RemotePost{} = parent <- [remote_parent(post)],
          Vutuv.Fediverse.subject_key(parent) not in taken,
          do: %{post_id: post.id, remote_post: parent}

    case Enum.uniq_by(parents, &Vutuv.Fediverse.subject_key(&1.remote_post)) do
      [] ->
        entries

      unique ->
        # **One card per cached post per page**, the rule `dedupe_remote/1`,
        # `collapse_reposts/1` and `attach_thread_notes/3` already hold for the
        # other kinds — and here it is not about repetition. The card's action
        # bar is a LiveComponent keyed by the cached post
        # (`RemoteActionsComponent.dom_id(:remote_post, id)`), so a second card
        # emits a duplicate LiveView id, which raises inside
        # `render_pending_components/6` during the **static** render: the page
        # 500s rather than degrading. Two members answering the same post out
        # there is ordinary behaviour, and the first such pair in the database
        # took /feed down for every reader who had both answers on one page
        # (2026-08-28).
        #
        # `unique` therefore decides where the card renders as well as which
        # batch reads run, and the placement is built from the decorated list
        # itself — the older version kept a second list to re-expand from, and
        # a comment saying the repeats "must not pay for the batch reads, not
        # the places they render" is exactly how the trap was rationalised.
        # The answers that do not claim it keep their "Replying to …" line,
        # which is what this feature replaced and still beats an error page.
        by_post =
          unique
          |> attach_remote_images()
          |> attach_remote_follows(viewer)
          |> attach_remote_likes(viewer)
          |> Map.new(&{&1.post_id, &1})

        Enum.map(entries, &claim_remote_parents(&1, by_post))
    end
  end

  defp claim_remote_parents(entry, by_post) do
    case Map.take(by_post, Enum.map(thread_posts(entry), & &1.id)) do
      mine when mine == %{} -> entry
      mine -> Map.put(entry, :remote_parents, mine)
    end
  end

  defp remote_parent(%Post{remote_reply_ref: %PostRemoteReply{remote_post: %RemotePost{} = p}}),
    do: p

  defp remote_parent(_post), do: nil

  # The cached posts that already have a card of their own on this page.
  defp standalone_remote_post_ids(remote),
    do:
      for(
        entry <- remote,
        entry[:remote_post],
        do: Vutuv.Fediverse.subject_key(entry.remote_post)
      )

  # The replies from other networks (issues #1069/#1071) that belong inside the
  # threads on this page, read once for the whole page and hung on the entries
  # that carry them.
  #
  # A conversation does not stop at the site's edge: somebody answers a member's
  # post from their own server, a member here answers *that*, and until this the
  # feed drew the two vutuv posts as one thread with the middle missing — which
  # reads as a member talking to themselves. The permalink has woven these in
  # since #1069; this is the same weave one surface over, and the renderer's
  # `weave_remote_replies/4` does the nesting for both.
  #
  # Capped per post (`Fediverse.list_feed_notes/3`), except for the ones a post
  # on the page answers: those are load-bearing, not decoration.
  #
  # **One card per reply per page**, the rule `dedupe_remote/1` and
  # `collapse_reposts/1` already hold for the other two kinds. A reply can reach
  # one page twice — as a row of its own because somebody here reshared it
  # (issue #1275), and inside the thread under the post it answers — and a
  # second card is not merely repetition: its action bar is a LiveComponent
  # keyed by the note, so the duplicate id takes the render down. The standalone
  # row wins, since it carries the reshare that put it there; within the threads
  # the first claim wins, because a post nested as an ancestor under one entry
  # can be the carrier of another.
  defp attach_thread_notes(entries, viewer, taken) do
    posts = for entry <- entries, post <- thread_posts(entry), do: post

    case Vutuv.Fediverse.list_feed_notes(Enum.map(posts, & &1.id), viewer,
           keep: Enum.flat_map(posts, &answered_note_ids/1)
         ) do
      empty when empty == %{} ->
        entries

      notes ->
        marks = notes |> Map.values() |> List.flatten() |> Vutuv.Fediverse.mark_lookup(viewer)

        {entries, _seen} =
          Enum.map_reduce(entries, MapSet.new(taken), &claim_thread_notes(&1, &2, notes, marks))

        entries
    end
  end

  defp claim_thread_notes(entry, seen, notes, marks) do
    mine =
      entry
      |> thread_posts()
      |> Map.new(fn post ->
        {post.id, Enum.reject(notes[post.id] || [], &(Vutuv.Fediverse.subject_key(&1) in seen))}
      end)
      |> Map.reject(fn {_post_id, notes} -> notes == [] end)

    if mine == %{} do
      {entry, seen}
    else
      claimed =
        for {_post_id, notes} <- mine,
            note <- notes,
            into: seen,
            do: Vutuv.Fediverse.subject_key(note)

      {entry |> Map.put(:remote_replies, mine) |> Map.put(:note_marks, marks), claimed}
    end
  end

  # The notes that already have a row of their own on this page (issue #1275).
  defp standalone_note_ids(remote),
    do: for(entry <- remote, entry[:note], do: Vutuv.Fediverse.subject_key(entry.note))

  @doc """
  Every vutuv post a feed entry draws: the carrier and the thread nested under
  it.

  Public because it is also what decides whether the reader's content filters
  hide the row. A feed entry is a *conversation*, not a post — an answer arrives
  with the posts it answers — so anything asking "what is on this row" has to
  ask here rather than reading `entry.post` and missing the rest.
  """
  def thread_posts(%{post: %Post{} = post} = entry), do: [post | entry[:ancestors] || []]
  def thread_posts(_entry), do: []

  # The remote reply this post answers (issue #1070), if it answers one at all.
  defp answered_note_ids(%Post{remote_reply_ref: %PostRemoteReply{note_id: id}})
       when is_binary(id),
       do: [id]

  defp answered_note_ids(_post), do: []

  defp decorate_remote([], _viewer), do: []

  defp decorate_remote(remote, viewer) do
    # Two shapes arrive here. A cached post, and a **reply** somebody here
    # passed on (issue #1275), which carries a `note` and no `remote_post` at
    # all — so deduping, the images and the follow, all of which read
    # `entry.remote_post`, raise on one: the same split `decorate_feed_entries/2`
    # makes one level up, for the same reason. The marks are read for both kinds
    # together, which is exactly what `Fediverse.mark_lookup/2` takes a mixed
    # list for.
    {replies, posts} = Enum.split_with(remote, &remote_reply_entry?/1)

    posts =
      posts
      |> dedupe_remote()
      |> attach_remote_images()
      |> attach_remote_follows(viewer)

    attach_remote_likes(posts ++ replies, viewer)
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
    |> Enum.uniq_by(&Vutuv.Fediverse.subject_key(&1.remote_post))
  end

  # What the reader has already done with each of the page's remote posts
  # (issues #1164, #1166 and #1276), read once for the whole page. It rides the
  # entry rather than a socket-level set because the feed re-renders a card by
  # re-inserting its entry into the stream, so the state a card draws from has
  # to live on the entry it draws.
  defp attach_remote_likes(remote, viewer) do
    subjects = Enum.map(remote, &remote_subject/1)
    marks = Vutuv.Fediverse.mark_lookup(subjects, viewer)

    Enum.map(remote, &Map.put(&1, :marks, marks.(remote_subject(&1))))
  end

  # What a remote entry is about: the cached post, or the reply a member here
  # passed on. Both wear the same action bar, so both have marks to read.
  defp remote_subject(entry), do: entry[:remote_post] || entry.note

  # Whether the reader follows each card's author, read once for the whole page.
  # The card's ⋯ menu offers Mute and Unfollow only where there is a follow to
  # act on, and a feed carries plenty of posts by accounts nobody here follows:
  # a boost by a followed account, a member's reshare. Rides the entry for the
  # same reason the like marks do.
  defp attach_remote_follows(remote, nil),
    do: Enum.map(remote, &Map.put(&1, :following?, false))

  defp attach_remote_follows(remote, viewer) do
    account_ids = Enum.map(remote, & &1.remote_post.remote_account_id)
    followed = Vutuv.Fediverse.followed_remote_account_ids(viewer, account_ids)

    Enum.map(
      remote,
      &Map.put(&1, :following?, MapSet.member?(followed, &1.remote_post.remote_account_id))
    )
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

  # The reader's own posts, and nothing else — what the feed calendar's
  # "My posts" reading shows in the timeline as well as in the shading.
  #
  # Deliberately the same set `own_post_counts_by_day/3` counts: a day the
  # heatmap shades under "My posts" has to be a day this timeline can fill, and
  # two definitions of "mine" would drift the first time one of them learned
  # about reshares. It is therefore posts the member WROTE, not posts they
  # passed on.
  #
  # No visibility scoping and no language filter: every one of these is the
  # reader's own, they may always see it, and a member who wrote in a language
  # they do not follow still wrote it.
  defp feed_own_post_items(%User{id: viewer_id}, fetch_n, cursor) do
    from(p in Post,
      as: :post,
      where: p.user_id == ^viewer_id,
      order_by: [desc: p.inserted_at, desc: p.id],
      limit: ^fetch_n
    )
    |> posts_at_or_before(cursor)
    |> Repo.all()
    |> Enum.map(&%{id: "post-#{&1.id}", post: &1, reposted_by: nil, at: &1.inserted_at})
  end

  defp feed_post_items(%User{id: viewer_id} = viewer, fetch_n, cursor) do
    from(p in Post,
      as: :post,
      join: u in assoc(p, :user),
      as: :author,
      where:
        p.user_id == ^viewer_id or p.user_id in subquery(followees_of(viewer_id)) or
          exists(subquery(delivered_by_past_follow(viewer_id))),
      where: p.user_id == ^viewer_id or account_confirmed_row(u),
      # Blocking used to cover itself here: it severs the follow, and the clause
      # above read nothing but the live follow set. An ended follow keeps
      # delivering now (issue #1673), so this source needs the same explicit
      # filter the repost source has always carried. `p.user_id` cannot be NULL
      # under the inner join above, so the bare `NOT IN` is safe here.
      where: p.user_id not in subquery(blocked_either_way(viewer_id)),
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
      as: :post,
      join: o in Organization,
      as: :organization,
      on: o.id == p.organization_id,
      where:
        p.organization_id in subquery(followed_organizations_of(viewer_id)) or
          exists(subquery(delivered_by_past_follow(viewer_id))),
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
  defp feed_repost_items(viewer, fetch_n, cursor),
    do: feed_repost_source(viewer, fetch_n, cursor, :followed)

  # And the same rows for the other reason they can reach a reader: the post is
  # **theirs**, or one they passed on, so whoever reshared it is news to them
  # whether or not they follow that person.
  defp feed_repost_of_mine_items(viewer, fetch_n, cursor),
    do: feed_repost_source(viewer, fetch_n, cursor, :about_me)

  # One query for both, because everything except the gate is the same — the
  # join graph, the cursor's `as: :repost` binding, the order, and how a row
  # becomes an entry. Written twice, the copies drifted the same afternoon they
  # were written.
  defp feed_repost_source(%User{id: viewer_id} = viewer, fetch_n, cursor, reach) do
    from(p in Post,
      as: :owned_post,
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
      where: ^repost_reach(reach, viewer_id),
      # A repost must not amplify an author the site hides. For a member that is
      # their account standing; for a page it is the page's own
      # (`organization_public_row/1`), so a frozen page stops being passed on.
      where:
        (not is_nil(p.user_id) and (p.user_id == ^viewer_id or account_confirmed_row(u))) or
          (not is_nil(p.organization_id) and organization_public_row(o)),
      # A third party's repost must not carry a blocked author's post into the
      # viewer's feed. The `is_nil` guard is not tidiness: on a reshared
      # *organization* post `p.user_id` is NULL, and `NULL NOT IN (<non-empty>)`
      # is NULL, so every page's reshared post silently left the feed of anybody
      # who had ever blocked one single person — and stayed for everybody else,
      # since `NULL NOT IN (<empty>)` is true.
      where: is_nil(p.user_id) or p.user_id not in subquery(blocked_either_way(viewer_id)),
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

  # What somebody **answered under one of the reader's own posts**, whoever they
  # are — the first of the two sources that is not about a follow at all.
  #
  # The feed asks "what have the people I follow said", which leaves a hole
  # around the reader themselves: a member they do not follow answers one of
  # their posts and the feed says nothing, so the conversation under their own
  # words happens somewhere they never look. `collapse_threads/1` then folds the
  # answer together with the post it answers, so what they see is their own post
  # with the new answer under it rather than a stranger's card out of nowhere.
  #
  # "Their own" covers **what they reshared** too: passing something on is
  # taking part in it, so what is said under it is theirs to see as well.
  #
  # Every gate the follow sources apply is asked here of somebody the reader has
  # no follow edge to — the author's standing, blocks either way, a mute they
  # placed, the post's own audience and their language filter. Their **own**
  # answers are excluded rather than deduplicated later: `feed_post_items/3`
  # already carries them, and the paginator's `more?` counts rows, not cards.
  defp feed_reply_to_me_items(%User{id: viewer_id} = viewer, fetch_n, cursor) do
    from(p in Post,
      as: :post,
      join: u in assoc(p, :user),
      as: :author,
      join: r in PostReply,
      as: :reply,
      on: r.post_id == p.id,
      # `post_replies` answers both halves by itself: it carries the denormalized
      # `parent_author_id` (with `(parent_author_id, inserted_at)` behind it,
      # which is how `Vutuv.Activity` already asks "replies to me") and the
      # parent's id. A second join to `posts` for the same two columns is a join
      # of the largest table on the hottest read path.
      where: ^reply_to_a_post_of_mine(viewer_id),
      # Their own replies arrive through `feed_post_items/3`, and a followee's
      # through the same source — excluded in the **query**, because the
      # paginator counts rows for `more?` and pages by them, so a duplicate
      # would shorten the page and be dropped only much later, by
      # `collapse_threads/1`.
      where: p.user_id != ^viewer_id,
      where: p.user_id not in subquery(followees_of(viewer_id)),
      # `not account_hidden_row(u)` is deliberately absent: naming `as: :author`
      # is what makes `scope_visible/2` add exactly that (`and_author_shown/2`).
      where: account_confirmed_row(u),
      where: p.user_id not in subquery(silenced_by(viewer_id)),
      order_by: [desc: p.inserted_at, desc: p.id],
      limit: ^fetch_n
    )
    |> scope_visible(viewer)
    |> language_scope(feed_language_filter(viewer))
    |> posts_at_or_before(cursor)
    |> Repo.all()
    |> Enum.map(&%{id: "post-#{&1.id}", post: &1, reposted_by: nil, at: &1.inserted_at})
  end

  # The posts the reader passed on.
  defp reshared_by(viewer_id) do
    from(r in PostRepost, where: r.user_id == ^viewer_id, select: r.post_id)
  end

  # **"This act is about a post of mine"** — one the reader wrote, or one they
  # passed on. Two spellings of one rule, because the two sides read it off
  # different tables, and both are mirrored on the write side by
  # `stakeholder_ids/1`; `reshared_by/1` is what keeps the three in step.
  #
  # On `post_replies`, which carries the answered post's author and id itself —
  # so the reply source needs no second join to `posts` for them.
  defp reply_to_a_post_of_mine(viewer_id) do
    dynamic(
      [reply: r],
      r.parent_author_id == ^viewer_id or r.parent_post_id in subquery(reshared_by(viewer_id))
    )
  end

  # And on the post itself, for the sources that already hold it.
  defp about_a_post_of_mine(viewer_id) do
    dynamic(
      [owned_post: op],
      op.user_id == ^viewer_id or op.id in subquery(reshared_by(viewer_id))
    )
  end

  # The blocked and the muted in one list, so a caller asks once. Both halves
  # exclude NULLs at the source, which `NOT IN` needs.
  defp silenced_by(viewer_id) do
    union_all(blocked_either_way(viewer_id), ^muted_followees_of(viewer_id))
  end

  # Why a reshare reaches this reader — the one thing that differs between the
  # two sources `feed_repost_source/4` serves.
  #
  # `:followed` is the original: somebody they follow passed it on, and the
  # resharer has to be in good standing. `:about_me` is the post being **theirs**
  # (or one they reshared), where the resharer can be a stranger — so this arm
  # asks the standing question *and* the two the follow set used to answer
  # implicitly, since a blocked or muted member has no follow edge left to
  # filter on.
  defp repost_reach(:followed, viewer_id) do
    dynamic(^repost_reaches_me(viewer_id) and ^resharer_is_shown(viewer_id))
  end

  defp repost_reach(:about_me, viewer_id) do
    dynamic(
      [_p, r],
      ^about_a_post_of_mine(viewer_id) and (is_nil(r.user_id) or r.user_id != ^viewer_id) and
        ^resharer_is_shown(viewer_id) and ^resharer_not_silenced(viewer_id)
    )
  end

  # A stranger's reshare is refused for the two reasons a follow would otherwise
  # have carried. A page's reshare has no member to silence, hence the nil arm.
  defp resharer_not_silenced(viewer_id) do
    dynamic(
      [_p, r],
      is_nil(r.user_id) or r.user_id not in subquery(silenced_by(viewer_id))
    )
  end

  # Reshared by me, by somebody I follow, or by a page I follow (issue #1336).
  defp repost_reaches_me(viewer_id) do
    dynamic(
      [_p, r],
      r.user_id == ^viewer_id or r.user_id in subquery(followees_of(viewer_id)) or
        r.organization_id in subquery(followed_organizations_of(viewer_id)) or
        exists(subquery(reshared_by_past_follow(viewer_id)))
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
    # SQL, so one organization follow would silently empty any source that
    # excludes who you already follow.
    from(c in Follow,
      where: c.follower_id == ^viewer_id and c.muted == false and not is_nil(c.followee_id),
      select: c.followee_id
    )
  end

  # The other half of "whose posts belong in this feed" (issue #1673): not who
  # the viewer follows now, but what a follow already delivered before it ended.
  # True for a post published between the follow's start and the unfollow — so
  # the past stays put and nothing newer from that author ever arrives.
  #
  # EXISTS rather than an id list, because the answer depends on the post's own
  # timestamp and not only on its author. It is also the shape that stays honest
  # around the nullable author pair: an organization post has a NULL `user_id`,
  # which matches no span here instead of poisoning a `NOT IN`.
  #
  # The end of the span is **exclusive** and its start is not. Every timestamp
  # involved has second precision, so the two boundaries are ties waiting to
  # happen, and they are not equally bad: letting a post from the unfollow's own
  # second through would break the promise the member just made themselves
  # ("nothing new from this account"), while dropping one from that same second
  # only loses something they have already read.
  #
  # The cost was measured rather than guessed, on 300k posts by 5k authors: the
  # planner drives this query off `posts_recency_index` and filters — it did so
  # *before* this clause existed too, so the OR takes no index away. What it
  # adds is one index probe per candidate row. For an ordinary reader (50
  # follows, 662 rows scanned for a page of 10) that is 1340 buffer hits against
  # 674, both well under a millisecond. The worst case is a reader who follows
  # almost nobody, where the recency scan goes deep before it finds ten posts:
  # at 16,779 rows scanned it cost 9-13 ms against 4-8 ms. Roughly double on the
  # pathological page, and the deep scan itself — not this clause — is what
  # makes that page slow.
  # One helper for both author kinds: exactly one of the two followee columns is
  # set on a span and exactly one of the two author columns on a post, and
  # `NULL = NULL` is not true — so a member's span can never match a page's post
  # or the other way round, and neither source needs to know about the other.
  defp delivered_by_past_follow(viewer_id) do
    from(w in PastFollow,
      where: w.follower_id == ^viewer_id,
      where:
        w.followee_id == parent_as(:post).user_id or
          w.followee_organization_id == parent_as(:post).organization_id,
      where: parent_as(:post).inserted_at >= w.started_at,
      where: parent_as(:post).inserted_at < w.ended_at
    )
  end

  # The same question for a reshare, which reaches the feed through whoever
  # passed it on: the span is read against the *repost's* time, since that is
  # when it was delivered. Its own function only because `parent_as/1` names the
  # outer binding at compile time and this one hangs off `:repost`.
  defp reshared_by_past_follow(viewer_id) do
    from(w in PastFollow,
      where: w.follower_id == ^viewer_id,
      where:
        w.followee_id == parent_as(:repost).user_id or
          w.followee_organization_id == parent_as(:repost).organization_id,
      where: parent_as(:repost).inserted_at >= w.started_at,
      where: parent_as(:repost).inserted_at < w.ended_at
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

  # The cursor's upper bound, and optionally its lower one.
  #
  # `since` is what makes "show me Tuesday" a *window* rather than "Tuesday and
  # everything before it" (the calendar's day pick, `Vutuv.Posts.feed_page/2`'s
  # `:since`). It rides in the cursor map on purpose: the cursor is the one
  # thing already threaded through every source and carried across pages by
  # `Vutuv.FeedPage`, so the bound survives "Load more" without a second
  # parameter to remember. A page whose rows have run out of the window simply
  # comes back short, which is what tells the paginator there is no more — no
  # row is ever fetched and then dropped, so `more?` cannot lie.
  defp posts_at_or_before(query, nil), do: query

  defp posts_at_or_before(query, %{at: at, since: since}) when not is_nil(since),
    do: where(query, [p], p.inserted_at <= ^at and p.inserted_at >= ^since)

  defp posts_at_or_before(query, %{at: at}), do: where(query, [p], p.inserted_at <= ^at)

  defp reposts_at_or_before(query, nil), do: query

  defp reposts_at_or_before(query, %{at: at, since: since}) when not is_nil(since),
    do: where(query, [repost: r], r.inserted_at <= ^at and r.inserted_at >= ^since)

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
  defp attach_reposters(entries, nil),
    do: Enum.map(entries, &(&1 |> Map.put(:reposters, []) |> Map.put(:reposters_total, 0)))

  defp attach_reposters(entries, %User{} = viewer) do
    # Keyed on "there is a resharer", not on "the resharer is a member": since
    # issue #1336 a page can reshare too, and a `%User{}` pattern here quietly
    # dropped those entries back to an empty roster — the banner then named
    # nobody on a post that was in the feed precisely because a page reshared it.
    post_ids = for %{reposted_by: by} = entry <- entries, not is_nil(by), do: entry.post.id

    # Which of them are the reader's own, answered here rather than by a join
    # back to `posts` in the roster query: every post is already in memory.
    own_ids =
      for %{reposted_by: by, post: post} <- entries,
          not is_nil(by),
          post.user_id == viewer.id,
          do: post.id

    rosters = reposter_rosters(post_ids, own_ids, viewer)

    Enum.map(entries, fn
      %{reposted_by: nil} = entry ->
        entry |> Map.put(:reposters, []) |> Map.put(:reposters_total, 0)

      entry ->
        %{names: names, total: total} =
          Map.get(rosters, entry.post.id, %{names: [entry.reposted_by], total: 1})

        entry
        |> Map.put(:reposters, names)
        |> Map.put(:reposters_total, total)
        |> Map.put(:reposted_by, hd(names))
    end)
  end

  defp reposter_rosters([], _own_ids, _viewer), do: %{}

  defp reposter_rosters(post_ids, own_ids, %User{id: viewer_id}) do
    # Same widening as `feed_repost_items/3` above, and for the same reason: the
    # banner names who reshared, and a page is now one of the answers.
    #
    # The last clause is the roster's half of `feed_repost_of_mine_items/3`: on
    # the reader's own post (or one they reshared) a **stranger's** reshare is
    # why the entry is here at all, so the roster has to hold them or the banner
    # names somebody else. It bit exactly that way — with the reader's own
    # reshare in the roster and the stranger's missing, the newest name was
    # replaced by the reader's own. Blocked and muted resharers stay out, the
    # same gate that source applies.
    ranked =
      from(r in PostRepost,
        left_join: u in User,
        on: u.id == r.user_id,
        left_join: rp in assoc(r, :organization),
        where: r.post_id in ^post_ids,
        where: ^roster_holds(viewer_id, own_ids),
        # Scoped per actor kind — see the note in `feed_repost_items/3`: a bare
        # `account_confirmed_row(u)` is TRUE on a left-joined missing row.
        where:
          r.user_id == ^viewer_id or
            (not is_nil(r.user_id) and account_confirmed_row(u)) or
            (not is_nil(r.organization_id) and organization_public_row(rp)),
        # Ids and the two window figures only: Ecto refuses a struct as a map
        # value inside a subquery, and the rows are hydrated by the outer query
        # below. The windows are computed over the **gated** set, so the total
        # counts what this reader may be shown and nothing else.
        select: %{
          id: r.id,
          post_id: r.post_id,
          rank:
            over(row_number(),
              partition_by: r.post_id,
              order_by: [desc: r.inserted_at, desc: r.id]
            ),
          total: over(count(r.id), partition_by: r.post_id)
        }
      )

    from(row in subquery(ranked),
      join: r in PostRepost,
      on: r.id == row.id,
      left_join: u in User,
      on: u.id == r.user_id,
      left_join: rp in assoc(r, :organization),
      where: row.rank <= ^@roster_cap,
      order_by: [asc: row.post_id, asc: row.rank],
      select: {row.post_id, row.total, u, rp}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0))
    |> Map.new(fn {post_id, rows} ->
      names = for {_post_id, _total, user, page} <- rows, do: user || page
      {_post_id, total, _user, _page} = hd(rows)
      {post_id, %{names: names, total: total}}
    end)
  end

  # Whose reshare of these posts the banner may name: the reader's own, a
  # followed member's or a followed page's — plus, on a post of the reader's
  # own, anybody's (`feed_repost_of_mine_items/3`'s half), minus the people they
  # blocked or muted.
  defp roster_holds(viewer_id, own_ids) do
    dynamic(
      [r, _u, _rp],
      r.user_id == ^viewer_id or r.user_id in subquery(followees_of(viewer_id)) or
        r.organization_id in subquery(followed_organizations_of(viewer_id)) or
        ((r.post_id in ^own_ids or r.post_id in subquery(reshared_by(viewer_id))) and
           (is_nil(r.user_id) or r.user_id not in subquery(silenced_by(viewer_id))))
    )
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
  the entry's own id (`ref_id`) rather than by when the entry was made.

  Two deliberate differences from the website's version, both forced by what a
  Mastodon client hands back.

  **The walk is bounded on `ref_id` — the entry's own id, which is the id every
  rendered status reduces to.** For an original that is the post; for a reshare
  it is the reshare row, because
  `Vutuv.MastodonApi.Presenter.reshared/2` renders a reshare as a status of its
  own (`repost-<uuid>`) and a client hands *that* back. Bounding on `post_id`
  instead — which this did while a reshare was still flattened into the post it
  carried — compares the cursor against a different table's uuid: a reshare row
  is younger than nearly every post, so `post_id < <reshare id>` stays true for
  the whole table and the client is handed the same page for ever. Not a wrong
  window but an endless one, and only on an account that has reshared
  something. The order has to match the bound or the page repeats and skips
  rows; ordering by `ref_id` also puts a reshare where Mastodon puts it, at the
  moment it was passed on rather than at the age of the post it carries.

  And replies are **not** folded under the post they answer
  (`collapse_profile_threads/1`): a client's account timeline is a flat list, and
  folding would make a full page come back short, which reads to the client as
  the end of the list.
  """
  def author_statuses(%User{} = author, viewer, opts \\ []) do
    author
    |> author_timeline_query(viewer, :all)
    |> Keyset.scope(opts, :ref_id)
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
  `count_author_posts/3` for many members at once, as `%{user_id => count}` —
  one query for a whole page.

  Same query and same viewer scoping as the single count, so the figure a client
  reads in a timeline is the one it reads on a profile. Written for
  `Vutuv.MastodonApi.AccountCounts`, which explains why a whole page of them is
  needed at once.
  """
  def author_post_counts([], _viewer), do: %{}

  def author_post_counts(author_ids, viewer) when is_list(author_ids) do
    author_ids
    |> author_timeline_query(viewer, :all)
    |> group_by([t], t.author_id)
    |> select([t], {t.author_id, count()})
    |> Repo.all()
    |> Map.new()
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

  # Unlike the feed's `followees_of/1`, muted follows count here: muting only
  # silences a followee's posts, it does not turn them back into a stranger
  # worth suggesting.
  defp all_followees_of(viewer_id) do
    from(c in Follow,
      where: c.follower_id == ^viewer_id and not is_nil(c.followee_id),
      select: c.followee_id
    )
  end

  # The people the viewer told us to keep quiet.
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
  defp author_timeline_query(%User{id: author_id}, viewer, filter),
    do: author_timeline_query([author_id], viewer, filter)

  # **The author is a list, not one member**, so the same three legs answer both
  # one profile timeline and `author_post_counts/2`'s figure for a whole page of
  # authors. Each leg therefore also selects the author it belongs to, which is
  # what the batched count groups by; `author_entries/2` ignores the extra key.
  defp author_timeline_query(author_ids, viewer, filter) when is_list(author_ids) do
    originals =
      from(p in Post,
        where: p.user_id in ^author_ids,
        select: %{
          kind: type(^"post", :string),
          ref_id: p.id,
          post_id: p.id,
          author_id: p.user_id,
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
        where: r.user_id in ^author_ids,
        select: %{
          kind: type(^"repost", :string),
          ref_id: r.id,
          post_id: p.id,
          author_id: r.user_id,
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
        where: r.user_id in ^author_ids,
        # Re-asked rather than trusted: the author can narrow their post after
        # somebody here reshared it, and a timeline is a public page.
        where: rp.audience in ^RemotePost.open_audiences(),
        select: %{
          kind: type(^"remote_repost", :string),
          ref_id: r.id,
          post_id: r.remote_post_id,
          author_id: r.user_id,
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

  The Mastodon adapter reads it for a second reason (issue #1622): the local
  post a cached fediverse reply answers, to name as that reply's
  `in_reply_to_id`. The gate is the point there too — the note's own visibility
  (a public reply) says nothing about the post it answers, which its author can
  since have narrowed, and an id the reader's next request is refused for is
  worse than none.
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
  (the parent post is gone but its author remains — a member or the page it was
  published in the name of), `:gone` (author gone too), or `nil` (not a reply).
  The API (`PostJSON`), the agent docs (`PostDoc`) and the post card all render
  from this, so they can't disagree on what a reply points at. An un-preloaded
  `reply_ref` is a truthy `NotLoaded`, hence the struct matches.
  """
  def reply_ref_state(%Post{reply_ref: %PostReply{} = ref}) do
    cond do
      match?(%Post{}, ref.parent_post) -> {:parent, ref.parent_post}
      match?(%User{}, ref.parent_author) -> {:author_only, ref.parent_author}
      match?(%Organization{}, ref.parent_organization) -> {:author_only, ref.parent_organization}
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
      # Both kinds of parent author, at both levels (issue #1336): a member may
      # answer a post published in a page's name, so the parent card names and
      # links a page as readily as a member — and `author/1` would otherwise pay
      # a query per card to find out which.
      reply_ref: [
        :parent_author,
        :parent_organization,
        parent_post: [
          :images,
          :screenshot,
          :review,
          :organization,
          # Rendered as a full card, so its author's proven links come along
          # too (issue #1246) — same reason as the top-level `user` above.
          user: verified_links_preload(),
          tags: from(t in Tag, order_by: t.name),
          # The nested parent's own "Replying to …" line, local and remote: the
          # two states it can be in when it is a reply rather than a thread
          # starter. `parent_post: [:user, :organization]` is deliberately the
          # author alone — the grandparent is named and linked, never rendered.
          remote_reply_ref: [remote_post: :remote_account],
          reply_ref: [:parent_author, :parent_organization, parent_post: [:user, :organization]]
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
  defp verified_links_preload, do: VerifiedLinks.preload_spec()

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

  Not only authors: any member-or-page actor links through here — a liker in
  the permalink's row (issue #1410), a reposter, a chat party.
  """
  def author_path(%Post{} = post), do: author_path(author(post))
  def author_path(author), do: Vutuv.Identity.path(author)

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
  dimensions, which is what the pixelated preview and the `<img>` attributes describe.

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
    # AI-moderation limbo: until released, the bytes are owner/admin-only
    # (everyone else gets the pixelated preview or the placecard, and this proxy 404s).
    visible_to?(post_of(image), viewer) and
      (ImageScans.released?(image.moderation) or ImageScans.privileged_viewer?(image, viewer))
  end

  @doc """
  Whether `viewer` may fetch this image's **pixelated preview** — the blocky stand-in the
  AI scan's wait renders (issue #1720, `Vutuv.Moderation.Pixelation`).

  The mirror image of `image_visible_to?/2` on the moderation half: the post's
  audience decides as it always does, but the pixelated preview exists precisely *because*
  the picture is not released, so a released picture has no mosaic to serve and
  the proxy sends the reader to the real thing instead. A photo that is still
  in the composer (no post yet) has no audience but its uploader, who sees the
  picture itself.
  """
  def pixelated_visible_to?(%PostImage{post_id: nil}, _viewer), do: false

  def pixelated_visible_to?(%PostImage{} = image, viewer) do
    not ImageScans.released?(image.moderation) and visible_to?(post_of(image), viewer)
  end

  @doc """
  The pixelated preview URL to render in place of this photo, or `nil` when the card
  should fall back to the grey placecard: the picture is released, the wait has
  run past `Vutuv.Moderation.Pixelation.window_seconds/0`, or no mosaic was written.
  """
  def image_pixelated_url(%PostImage{} = image) do
    if not ImageScans.released?(image.moderation) and
         Pixelation.stands_in?(PostImageStore.pixelated_path(image.token), image.inserted_at),
       do: PostImage.pixelated_url(image)
  end

  # The post an image hangs on, preloaded or fetched. NotLoaded is truthy, so
  # this can never be written as an `||`.
  defp post_of(%PostImage{} = image) do
    case image.post do
      %Post{} = post -> post
      _not_preloaded -> Repo.get(Post, image.post_id)
    end
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
    |> Enum.filter(&Tag.names_a_topic?/1)
    |> Tags.canonical_tag_names()
  end

  # Find-or-create by name/slug (case-insensitive), racing gracefully.
  # Unresolvable values (e.g. names whose slug exceeds the limit) are skipped:
  # a post must not fail because one tag was odd. `Tags.find_or_create_tag_id/1`
  # owns the find-or-create, so a tag minted from a chip and one minted from a
  # `#hashtag` in the body are made — and raced — the same way.
  defp tag_ids_for(values) do
    values
    |> Enum.map(&Tags.find_or_create_tag_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
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
  # `[]`, not `:ok`: the return value is the recipient list a second fan-out
  # about the same event subtracts (`broadcast_about_post/3`).
  defp broadcast_new_post(%Post{user_id: nil}), do: []

  defp broadcast_new_post(%Post{} = post) do
    broadcast_to_followers(post.user_id, new_post_event(post))
  end

  # The push half of `feed_reply_to_me_items/3` and `feed_repost_of_mine_items/3`:
  # the people this act is *about* are not the actor's followers, so the ordinary
  # fan-out never reaches them and their feed would only catch up on the next
  # load.
  #
  # `told` is what the fan-out beside it just returned, rather than recomputed
  # here: asking again is a second identical `Follow` scan per write, and
  # rebuilding it from an actor id cannot express who a **page's** reshare
  # reached — `broadcast_to_followers/2` dispatches on the actor's kind and a
  # page's reposter id is NULL, so `follower_ids(nil)` would raise the
  # `where: x == ^nil` trap this milestone has paid for repeatedly.
  defp broadcast_about_post(%Post{} = post, told, event) do
    told = MapSet.new(told)

    post
    |> stakeholder_ids()
    |> Enum.reject(&MapSet.member?(told, &1))
    |> Enum.each(&Vutuv.Activity.broadcast(&1, event))
  end

  # Who a post is *about*: its author and everyone who passed it on. The pull
  # side asks the same question as a query (`about_a_post_of_mine/1`), so the two
  # have to mean the same thing — `feed_about_me_test.exs` asserts they do.
  defp stakeholder_ids(%Post{} = post) do
    post.id
    |> resharer_ids()
    |> List.insert_at(0, post.user_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp resharer_ids(post_id) do
    Repo.all(
      from(r in PostRepost,
        where: r.post_id == ^post_id and not is_nil(r.user_id),
        select: r.user_id
      )
    )
  end

  # `at` is the stamp this post will carry in the merged feed, the way the
  # fediverse nudge carries one (issue #1503): it lets a subscriber ask its own
  # sources for their newest row "at least as new as this" rather than trusting
  # the fan-out about who may see it. The browser tab's teaser needs exactly
  # that (issue #1681); every existing matcher takes the map apart by key and
  # is unaffected.
  defp new_post_event(%Post{} = post),
    do: {:new_post, %{post_id: post.id, author_id: post.user_id, at: post.inserted_at}}

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
  defp broadcast_new_repost(%PostRepost{} = repost, %Post{} = post) do
    reposter_id = repost.user_id || repost.organization_id

    event =
      {:new_repost, %{repost_id: repost.id, post_id: repost.post_id, reposter_id: reposter_id}}

    told = broadcast_to_followers(repost, event)

    # And the people it is about (see `broadcast_about_post/3`): being passed on
    # is news to the author whether or not they follow whoever did it. The post
    # comes from the caller, which already holds it — `get_post/1` would preload
    # its twenty associations to read one id.
    broadcast_about_post(post, told, event)
  end

  # A new reply ticks the parent's open action bars, notifies its author
  # (self-replies are not news) and tells the thread's other participants.
  #
  # An answer to a post published in a page's name notifies nobody here, and
  # that is the whole arrangement rather than a gap: the page's activity list is
  # **derived** from `post_replies.parent_organization_id`
  # (`Vutuv.Organizations.activity_page/2`), the way its likes and reposts are
  # derived, so an answer appears there — and disappears again with the row —
  # without anything being written twice. Guarded on the column rather than left
  # to `notify_reply/4`'s own nil tolerance: reading `nil != reply.user_id` as
  # "somebody to tell" is exactly the half-read pair that has cost this
  # milestone sixteen silent failures.
  defp broadcast_reply(%Post{} = parent, %Post{} = reply, told) do
    broadcast_reply_count(parent.id)
    broadcast_about_post(parent, told, new_post_event(reply))

    if is_binary(parent.user_id) and parent.user_id != reply.user_id do
      Vutuv.Activity.notify_reply(
        parent.user_id,
        reply.user,
        parent.id,
        reply.id,
        reply.reply_ref && reply.reply_ref.id
      )
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
      |> Enum.each(
        &Vutuv.Activity.notify_thread_reply(
          &1,
          reply.user,
          root_id,
          reply.id,
          reply.reply_ref.id
        )
      )
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
    mention_ids = insert_mentions(post, added)
    Enum.each(added, &notify_mentioned(post, &1, mention_ids[&1.id]))
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

  # Returns the new rows as `%{user_id => mention_id}`: the ids are minted here
  # (UUID v7, client-side), so the live push can name the very row the feed
  # will count without reading it back — which is what lets a member dismiss
  # that one mention by clicking its browser notification.
  defp insert_mentions(_post, []), do: %{}

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
    Map.new(rows, &{&1.user_id, &1.id})
  end

  # The actor is whoever the post is BY — the organization on an organization
  # post, never the member who pressed publish, which is exactly the split
  # `acting_user_id` exists to keep internal (issue #1334). `author/1` needs the
  # preload, and the mention sync runs on a freshly preloaded post.
  #
  # A block only guards the member case: a block is a relationship between two
  # people, and `blocked_between?/2` already answers false for a nil id.
  defp notify_mentioned(%Post{} = post, %User{} = mentioned, mention_id) do
    unless Vutuv.Social.blocked_between?(mentioned.id, post.user_id) do
      Vutuv.Activity.notify_mention(mentioned.id, author(post), post.id, mention_id)
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

  # Each clause **returns the ids it told**, so a second fan-out about the same
  # event (`broadcast_about_post/3`) can subtract them instead of re-deriving
  # them from an actor id — which no caller can do for a page anyway.
  defp broadcast_to_followers(%PostRepost{organization_id: page_id}, event)
       when is_binary(page_id) do
    # The people to tell are the PAGE's followers, and they hang off
    # `followee_organization_id`. Handing the page's id to the member query
    # would have compared `followee_id` with a nil reposter and RAISED - the
    # `where: x == ^nil` trap this milestone has paid for more than once.
    broadcast_each(organization_follower_ids(page_id), event)
  end

  defp broadcast_to_followers(%PostRepost{user_id: user_id}, event),
    do: broadcast_to_followers(user_id, event)

  defp broadcast_to_followers(user_id, event),
    do: broadcast_each([user_id | follower_ids(user_id)], event)

  defp broadcast_each(ids, event) do
    Enum.each(ids, &Vutuv.Activity.broadcast(&1, event))
    ids
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
