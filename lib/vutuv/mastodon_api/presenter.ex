defmodule Vutuv.MastodonApi.Presenter do
  @moduledoc "Mastodon-compatible JSON representations of vutuv identities and posts."

  alias Phoenix.HTML.Safe
  alias Vutuv.Accounts.User
  alias Vutuv.Avatar
  alias Vutuv.Cover
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemoteImage
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Identity
  alias Vutuv.MastodonApi
  alias Vutuv.MastodonApi.AccountCounts
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Organizations.Organization
  alias Vutuv.Organizations.OrganizationImage
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostImage
  alias Vutuv.Profiles.Url
  alias Vutuv.Profiles.VerifiedLinks
  alias Vutuv.RemoteMedia
  alias Vutuv.Tags.Tag
  alias Vutuv.UUIDv7
  alias VutuvWeb.Markdown
  alias VutuvWeb.RemoteMediaToken

  def identity_name(%User{} = user),
    do: Identity.display_name(user) <> " (@" <> user.username <> ")"

  def identity_name(%Organization{name: name}), do: name

  @doc """
  One account in Mastodon's shape.

  `counts` fills the three profile-header figures. Every account this adapter
  sends carries them, because a client renders a profile header from whichever
  copy of the account it happens to hold — see
  `Vutuv.MastodonApi.AccountCounts`, which reads them for a whole page at once
  and is what `statuses/2` fills them from. Passing them here is for the
  endpoints that answer with a **single** account; leaving them out keeps the
  entity's zeroes, which is only ever right for an account whose figures are not
  ours to state. Reading the member's own bio into `note` costs nothing, so that
  is always filled.
  """
  def account(subject, counts \\ nil)

  def account(%User{} = user, counts) do
    avatar = user_avatar(user)
    header = user_cover(user)

    base_account(%{
      id: account_id(user),
      username: user.username,
      acct: user.username,
      display_name: Identity.display_name(user),
      note: note(user.headline),
      created_at: created_at(user, user.id),
      url: profile_url(user),
      avatar: avatar,
      header: header,
      header_static: header,
      fields: account_fields(user),
      group: false
    })
    |> Map.merge(count_fields(counts))
  end

  def account(%Organization{} = organization, counts) do
    handle = acct_handle(organization)
    header = organization_image(organization.cover, fallback_header())

    base_account(%{
      id: account_id(organization),
      username: handle,
      acct: handle,
      display_name: organization.name,
      note: note(organization.description),
      created_at: created_at(organization, organization.id),
      url: profile_url(organization),
      avatar: organization_image(organization.logo, fallback_avatar()),
      header: header,
      header_static: header,
      group: true
    })
    |> Map.merge(count_fields(counts))
  end

  def account(%RemoteAccount{} = account, _counts) do
    handle = RemoteAccount.display_handle(account) |> String.trim_leading("@")
    username = handle |> String.split("@") |> hd()
    icon = remote_avatar(account)

    base_account(%{
      id: account_id(account),
      username: username,
      acct: handle,
      display_name: account.name || username,
      created_at: timestamp(account.inserted_at),
      url: account.actor_uri,
      avatar: icon,
      group: false
    })
  end

  @doc """
  A page of statuses as `viewer` sees them — the form every list endpoint here
  should use.

  The three counts under a post and the viewer's own like / bookmark / reshare
  flags are read for the whole page in **one** round trip
  (`Posts.post_engagement_map/2`), the same way the website's feed pre-loads
  them for its cards. Rendering a status at a time would be four queries per
  row, and rendering them without a viewer at all is what made every heart in
  every client sit empty on a post the member had just liked — so a client
  offered "like" on something already liked, and undid it.

  `viewer` is the acting identity: a `%User{}`, an `%Organization{}` for a page
  identity, or `nil`. Entries from other networks pass straight through — their
  counts travel with the record.
  """
  def statuses(items, viewer) when is_list(items) do
    context = page_context(items, viewer)

    items
    |> Enum.map(&rendered_status(&1, context))
    |> fill_account_counts(viewer)
  end

  # Everything a page reads **once** and every status on it then reads from.
  # Growing this map is how a new per-status fact arrives here; growing
  # `status/3`'s parameter list is not, which is what it already looked like.
  defp page_context(items, viewer) do
    post_ids = items |> Enum.map(&engaged_post_id/1) |> Enum.reject(&is_nil/1)
    remote_ids = items |> Enum.map(&remote_post_id/1) |> Enum.reject(&is_nil/1)
    note_parent_ids = items |> Enum.map(&note_parent_post_id/1) |> Enum.reject(&is_nil/1)
    self_reply_pairs = items |> Enum.map(&self_reply_pair/1) |> Enum.reject(&is_nil/1)

    # Both halves of the sidecar, in one map (issue #1622): the cached reply a
    # post answers (#1641) and the cached **post** it answers (#1165). Read from
    # the sidecar table rather than off the `:remote_reply_ref` preload, which
    # is what `answered_notes/1`'s own doc asks for — a parent that silently
    # depends on whether somebody remembered a preload is a shape that has
    # bitten this codebase before.
    answered = Fediverse.answered_objects(post_ids)
    remote_parents = Fediverse.remote_parent_posts(self_reply_pairs)

    %{
      viewer: viewer,
      engagements: Posts.post_engagement_map(post_ids, viewer),
      mentions: Posts.mention_map(post_ids),
      answered: answered,
      # The photographs on the cached posts this page shows (issue #1626).
      # `:images` is never preloaded on a `%RemotePost{}` — every surface in this
      # codebase batches them by id, and so does this one.
      remote_images: Fediverse.list_remote_images(remote_ids),
      # The local post each cached reply answers (issue #1622), batched and
      # already scoped to what `viewer` may see.
      note_parents: Posts.visible_posts_by_ids(viewer, note_parent_ids),
      # The cached parent of a followed account's self-reply, batched the same
      # way (`Fediverse.remote_parent_posts/1`).
      remote_parents: remote_parents,
      # Which of those cached parents `viewer` may actually read — the half
      # `answered_objects/1` hands over ungated on purpose, because only the
      # renderer knows the reader. One `Fediverse.remote_post_readable?/2` for
      # the whole page, and no query at all when every parent is public.
      readable_parents:
        Fediverse.readable_remote_post_ids(
          Map.values(remote_parents) ++ answered_remote_posts(answered),
          viewer
        )
    }
  end

  defp answered_remote_posts(answered),
    do: for({_post_id, %RemotePost{} = post} <- answered, do: post)

  # What a single status rendered outside `statuses/2` gets. Built by the same
  # function rather than spelled out again, so the next batch cannot be added to
  # one shape and forgotten in the other; every batch short-circuits on an empty
  # id list, so it costs no query.
  defp no_page, do: page_context([], nil)

  # The figures on every account this page embeds, written in after the fact
  # rather than threaded through `status/2`: a status reaches its author through
  # half a dozen shapes (a post, a reshare of one, a cached post from another
  # network), and each of them would otherwise have to remember to carry the
  # counts along. See `Vutuv.MastodonApi.AccountCounts` for why they have to be
  # there at all.
  defp fill_account_counts(statuses, viewer) do
    counts = AccountCounts.for_statuses(statuses, viewer)
    Enum.map(statuses, &counted_status(&1, counts))
  end

  defp counted_status(%{reblog: %{} = inner} = status, counts),
    do: %{counted_account(status, counts) | reblog: counted_account(inner, counts)}

  defp counted_status(status, counts), do: counted_account(status, counts)

  defp counted_account(%{account: %{id: id} = account} = status, counts) do
    case counts[id] do
      nil -> status
      figures -> %{status | account: Map.merge(account, count_fields(figures))}
    end
  end

  defp counted_account(status, _counts), do: status

  @doc """
  One status as `viewer` sees it — `statuses/2` for a single row.

  **It fills the author's counts too, and that is the point rather than a side
  effect of reusing the page path.** This is what answers a status action, a
  fresh post and an edit, and a client keeps the account object out of any of
  them: handing back zeroes on the reply to a like would put the very "0 posts"
  back into a profile header that the counts exist to fix. The bill is the four
  aggregates in `Vutuv.MastodonApi.AccountCounts` for a single member — and
  nothing at all when the author is on another network, since there are no local
  ids to count and the batch short-circuits before it queries.
  """
  def one_status(item, viewer), do: item |> List.wrap() |> statuses(viewer) |> hd()

  @doc """
  One reshare a caller assembled for itself, as a status.

  Every other reshare here arrives as a feed entry from the source that built it
  (`Vutuv.Posts`, `Vutuv.Fediverse`). This is for the one caller with no feed
  entry to hand over: `VutuvWeb.MastodonApi.StatusController.delete/2` answering
  an undo with the reshare the client addressed, which by then is a row it is
  about to remove. It lives here so the entry shape keeps one owner instead of
  being hand-built in a controller.

  `reshare` is `%{kind:, object:, at:}` as
  `VutuvWeb.MastodonApi.Statuses.own_reshare/2` answers it — `kind` is the key
  the object rides under — and `actor` is both the resharer and the viewer,
  since that function only ever hands back the caller's own act.
  """
  def reshared_status(id, %{kind: kind, object: object, at: at}, actor) do
    %{id: id, reposted_by: actor, at: at}
    |> Map.put(kind, object)
    |> one_status(actor)
  end

  # The map clauses are for feed-entry maps only: a `%Note{}` also carries a
  # `post` association, so without the guard a Note whose `:post` happens to be
  # preloaded would render as its parent post instead of itself.
  defp engaged_post_id(%Post{id: id}), do: id
  defp engaged_post_id(%{post: %Post{id: id}} = entry) when not is_struct(entry), do: id
  defp engaged_post_id(_other), do: nil

  # The same, for the cached posts whose photographs the page has to look up.
  defp remote_post_id(%RemotePost{id: id}), do: id

  defp remote_post_id(%{remote_post: %RemotePost{id: id}} = entry) when not is_struct(entry),
    do: id

  defp remote_post_id(_other), do: nil

  # The local post id a cached reply's `Note.post_id` names, for the
  # `note_parents` batch — same map-vs-struct shape as every other extractor
  # here.
  defp note_parent_post_id(%Note{post_id: id}) when is_binary(id), do: id

  defp note_parent_post_id(%{note: %Note{post_id: id}} = entry)
       when not is_struct(entry) and is_binary(id),
       do: id

  defp note_parent_post_id(_other), do: nil

  # The `{in_reply_to_uri, remote_account_id}` pair `own_thread?/2` gated a
  # cached post's own parent by, for the `remote_parents` batch.
  defp self_reply_pair(%RemotePost{in_reply_to_uri: uri, remote_account_id: account_id})
       when is_binary(uri),
       do: {uri, account_id}

  defp self_reply_pair(
         %{remote_post: %RemotePost{in_reply_to_uri: uri, remote_account_id: account_id}} =
           entry
       )
       when not is_struct(entry) and is_binary(uri),
       do: {uri, account_id}

  defp self_reply_pair(_other), do: nil

  defp rendered_status(%Post{} = post, context), do: status(post, context)

  defp rendered_status(%{post: %Post{} = post} = entry, context) when not is_struct(entry),
    do: reshared(entry, status(post, context))

  defp rendered_status(other, context), do: status_from_entry(other, context)

  # A reshare in Mastodon's shape: an outer status by whoever passed the post
  # on, carrying the post itself under `reblog`.
  #
  # **Every feed source here can hand over a reshare, and all of them were
  # flattened.** A merged-feed entry names its resharer in `reposted_by` (a
  # member or a page here) or in `boosted_by` (an account on another network),
  # and this module dropped both: the post was rendered as if its own author had
  # just written it. So a client showed a stranger's post in the middle of a
  # member's home timeline with no line saying who passed it on — and the same
  # on a member's own profile, where their reshares are part of their timeline
  # (`Posts.author_statuses/3`), which is why "my own posts" read as
  # everybody's.
  #
  # The wrapper is Mastodon's, down to the empty `content` and the `url` of
  # `null`: a client renders the inner status and takes the outer one only for
  # the "X boosted" line. The counts stay on the inner status, which is where a
  # client reads them.
  defp reshared(entry, inner) do
    case resharer(entry) do
      nil ->
        inner

      sharer ->
        base_status(%{
          id: reshare_id(entry, inner),
          created_at: reshare_time(entry) || inner.created_at,
          account: account(sharer),
          content: "",
          url: nil,
          uri: inner.uri,
          visibility: inner.visibility,
          reblog: inner
        })
    end
  end

  # A resharer is a member or page here (`reposted_by`) or an account out there
  # (`boosted_by`); an entry that is nobody's reshare has both nil, and a bare
  # struct has neither key.
  defp resharer(%{reposted_by: %{} = sharer}), do: sharer
  defp resharer(%{boosted_by: %RemoteAccount{} = sharer}), do: sharer
  defp resharer(_not_a_reshare), do: nil

  # **The reshare is its own status and needs its own id**, or a boost and the
  # post it carries are one entry to a client that keys its timeline by id — and
  # the id is also the pagination cursor, whose timestamp must be when the post
  # was *passed on*, not when it was written. Feed entries already carry exactly
  # that id (`boost-<uuid>`, `repost-<uuid>`, …), built on the reshare row's own
  # UUIDv7; `VutuvWeb.MastodonApi.Pagination.bare_id/1` reads the uuid back out
  # of it, and `VutuvWeb.MastodonApi.StatusController` resolves it to the post.
  defp reshare_id(%{id: id}, _inner) when is_binary(id), do: id
  defp reshare_id(_entry, inner), do: inner.id

  defp reshare_time(%{at: at}), do: timestamp(at)
  defp reshare_time(_entry), do: nil

  @doc """
  The id a client is handed for one object — the same string
  `VutuvWeb.MastodonApi.StatusController` resolves back.

  One spelling of the three shapes, so a status and anything that *names* it (a
  thread's parent link, an `in_reply_to_id`) cannot drift apart.
  """
  def status_id(%Post{id: id}), do: id
  def status_id(%RemotePost{id: id}), do: "remote-" <> id
  def status_id(%Note{id: id}), do: "remote-note-" <> id

  @doc """
  The id a client is handed for one account — its twin, and the string
  `VutuvWeb.MastodonApi.AccountController` resolves back.

  Worth its own function for the same reason: `in_reply_to_account_id` names an
  account the client is expected to match against one it already holds, so the
  two must be minted in one place.
  """
  def account_id(%User{id: id}), do: id
  def account_id(%Organization{id: id}), do: id
  def account_id(%RemoteAccount{id: id}), do: "remote-" <> id

  # One status. `context` carries everything the page read once (`page_context/2`);
  # a caller outside `statuses/2` gets the empty one and every lookup simply
  # misses.
  defp status(%Post{} = post, context) do
    author = Posts.author(post)
    engagement = context.engagements[post.id]
    # The reader every picture on this post is named for, or nil where it needs
    # no credential — which is every public post. Decided once: the body's
    # inline copies and the attachments must reach the same file the same way.
    photo_viewer = if restricted?(post, engagement), do: context.viewer
    content = content_html(post, photo_viewer)

    fields =
      %{
        id: status_id(post),
        created_at: timestamp(post.inserted_at),
        content: content,
        url: MastodonApi.main_url(Posts.path(post)),
        uri: MastodonApi.main_url(Posts.path(post)),
        account: account(author),
        media_attachments: media_attachments(post, photo_viewer),
        visibility: visibility(post, engagement),
        language: post.language,
        edited_at: edited_at(post),
        tags: status_tags(post),
        mentions: status_mentions(post, context.mentions[post.id])
      }
      |> Map.merge(reply_fields(post, context.answered[post.id], context))
      |> Map.merge(engagement_fields(engagement))

    base_status(fields)
  end

  defp status(%RemotePost{} = post, context) do
    fields =
      %{
        id: status_id(post),
        created_at: timestamp(post.published_at),
        content: remote_content_html(post.content_text),
        url: post.origin_url || post.object_uri,
        uri: post.object_uri,
        account: account(post.remote_account),
        media_attachments: remote_attachments(post, context),
        sensitive: post.sensitive,
        spoiler_text: post.summary || ""
      }
      |> Map.merge(remote_post_reply_fields(post, context))

    base_status(fields)
  end

  # A cached **reply** carries no pictures at all: there is no note-image table
  # and the inbox stores none, on the reply cards' own stance that a stranger's
  # picture is not copied here (`Vutuv.Fediverse.Note`). So this head has nothing
  # to name, and an empty `media_attachments` is the true answer rather than an
  # unfinished one.
  defp status(%Note{} = note, context) do
    fields =
      %{
        id: status_id(note),
        created_at: timestamp(note.received_at),
        content: remote_content_html(note.content_text),
        url: Note.origin(note),
        uri: note.object_uri,
        account: note_account(note),
        sensitive: Note.warned?(note),
        spoiler_text: note.summary || "",
        favourites_count: note.likes_count || 0,
        reblogs_count: note.shares_count || 0
      }
      |> Map.merge(note_reply_fields(note, context))

    base_status(fields)
  end

  @doc """
  One feed entry as a status — a reshare included, which is why this wraps
  rather than only unwrapping (`reshared/2`).

  It is also what the timeline endpoints read the pagination boundary out of, so
  the id it answers for a reshare has to be the reshare's own.
  """
  def status_from_entry(entry, context \\ no_page()),
    do: reshared(entry, inner_status_from_entry(entry, context))

  # **A row from another network also arrives on its own, not only wrapped in a
  # feed entry.** The map clauses below read the merged feed's entry maps, and
  # every caller that hands over a bare struct instead fell straight through
  # them into a `FunctionClauseError` — a 500 with an HTML body, to a client
  # that decodes every answer as JSON. Two live paths did exactly that:
  # `Fediverse.recent_public_remote_posts/1` answers bare `%RemotePost{}`
  # structs, so a client's **Federated** tab 500ed the moment this site had
  # cached a single post (which reads as "no posts found"); and
  # `one_status/2` renders the answer to every status action, so favouriting,
  # boosting or bookmarking anything from another network failed *after* the
  # like had already been written and delivered.
  #
  # The struct clauses come first on purpose: a `%Note{}` also carries a `post`
  # association, so with the map clauses ahead a Note whose `:post` happens to
  # be preloaded would render as its parent post instead of itself.
  defp inner_status_from_entry(%RemotePost{} = post, context), do: status(post, context)
  defp inner_status_from_entry(%Note{} = note, context), do: status(note, context)
  defp inner_status_from_entry(%Post{} = post, context), do: status(post, context)

  defp inner_status_from_entry(%{remote_post: %RemotePost{} = post}, context),
    do: status(post, context)

  defp inner_status_from_entry(%{note: %Note{} = note}, context), do: status(note, context)
  defp inner_status_from_entry(%{post: %Post{} = post}, context), do: status(post, context)

  defp count_fields(nil), do: %{}

  defp count_fields(counts) do
    %{
      followers_count: counts[:followers] || 0,
      following_count: counts[:following] || 0,
      statuses_count: counts[:statuses] || 0
    }
  end

  # Mastodon's `note` is HTML, and a vutuv headline or page description is
  # plain text a member typed. Escaped and wrapped in one paragraph, so a
  # client renders the words rather than parsing whatever was in them.
  defp note(text) when is_binary(text) and text != "",
    do: "<p>" <> Plug.HTML.html_escape(text) <> "</p>"

  defp note(_blank), do: ""

  @doc """
  The picture stood in for an account we hold no avatar for — a page, a remote
  actor, a member whose avatar is the generated placeholder.

  One function rather than the same literal in five places, so an installation
  that changes its icon changes it everywhere at once.
  """
  def fallback_avatar, do: MastodonApi.main_url("/images/icon-512.png")

  @doc """
  The banner stood in for an account with no cover picture — a remote actor
  (we cache no banner for one), a page or a member who never uploaded one.

  A separate picture from `fallback_avatar/0` on purpose: a square app icon
  stretched across a profile header is what a client showed until now, and it
  reads as a broken image rather than as an empty banner. This is the brand
  gradient the website's own coverless profile draws, so the two surfaces agree.
  Still a URL and never nil — Mastodon types `header` as a string, and a client
  decoding the account into a non-optional field drops the whole account over a
  null.
  """
  def fallback_header, do: MastodonApi.main_url("/images/header-placeholder.png")

  @doc """
  The keys every account carries, under the ones a caller filled in.

  Public because an account is also built outside this module — the stand-in for
  a remote actor in `Vutuv.MastodonApi.Notifications`. A client reads `emojis`,
  `fields` and the counts without checking, so a hand-built map that skips them
  hands it a `nil` where it expects a list; going through here is what makes
  that impossible.
  """
  def base_account(fields) do
    Map.merge(
      %{
        locked: false,
        bot: false,
        discoverable: true,
        group: false,
        note: "",
        header: fallback_header(),
        header_static: fallback_header(),
        avatar_static: fields.avatar,
        followers_count: 0,
        following_count: 0,
        statuses_count: 0,
        last_status_at: nil,
        noindex: false,
        emojis: [],
        roles: [],
        fields: []
      },
      fields
    )
  end

  defp base_status(fields) do
    Map.merge(
      %{
        in_reply_to_id: nil,
        in_reply_to_account_id: nil,
        reblog: nil,
        sensitive: false,
        spoiler_text: "",
        visibility: "public",
        language: nil,
        replies_count: 0,
        reblogs_count: 0,
        favourites_count: 0,
        edited_at: nil,
        media_attachments: [],
        mentions: [],
        tags: [],
        emojis: [],
        card: nil,
        poll: nil,
        favourited: false,
        reblogged: false,
        muted: false,
        bookmarked: false,
        pinned: false,
        application: nil,
        filtered: []
      },
      fields
    )
  end

  # Mastodon's profile `fields`, filled from the webpages a member has PROVED
  # are their own (`Vutuv.Profiles.LinkVerification`) — the rel=me / DNS /
  # well-known proofs the website marks with an emerald tick. That is the same
  # claim `verified_at` makes in a client, which is why these and not the whole
  # link list: an unproven link rendered here would carry no `verified_at`, and
  # a client draws no distinction between "not proved" and "a plain row", so it
  # would read as the member's own list of trusted addresses.
  #
  # They are already preloaded wherever a post renders
  # (`Posts.render_preloads/0` scopes the author's `:urls` to exactly this set),
  # so a page of statuses pays nothing; an account whose links were not loaded
  # answers the empty list rather than raising, like every other association
  # here.
  defp account_fields(%User{} = user),
    do: user |> VerifiedLinks.of() |> Enum.map(&account_field/1)

  defp account_field(%Url{} = link) do
    address = VerifiedLinks.address(link)

    %{
      name: field_name(link, address),
      value: field_value(link, address),
      verified_at: timestamp(link.verified_at)
    }
  end

  defp field_name(%Url{description: description}, _address)
       when is_binary(description) and description != "",
       do: description

  defp field_name(_link, address), do: address

  # HTML, because Mastodon's field value is: a client renders it as markup and
  # follows the anchor. `rel="me"` is the same statement the proof itself rests
  # on.
  defp field_value(%Url{value: value}, address) do
    ~s(<a href=") <>
      Plug.HTML.html_escape(value) <>
      ~s(" rel="me nofollow noopener noreferrer" target="_blank">) <>
      Plug.HTML.html_escape(address) <> "</a>"
  end

  # The AI image gate is not re-asked here: `Vutuv.Uploads.url/3` answers "no
  # image" for a picture still in moderation limbo (the file waits in
  # quarantine), so a pending avatar already comes back as the `data:` default
  # and a pending cover as nil — the same chokepoint every website surface
  # reads, and the stand-in falls out of it.
  defp user_avatar(user) do
    case Avatar.display_url(user, :thumb) do
      "/" <> _path = relative -> MastodonApi.main_url(relative)
      "data:" <> _placeholder -> fallback_avatar()
      absolute -> absolute
    end
  end

  # The member's own banner, which this never sent at all: `base_account/1`
  # filled `header` with the installation's icon and nothing overrode it for a
  # member, so a client drew the vutuv logo across the top of every profile —
  # including profiles that have carried a cover photo for years.
  defp user_cover(user) do
    case Cover.display_url(user, :wide) do
      path when is_binary(path) -> MastodonApi.main_url(path)
      nil -> fallback_header()
    end
  end

  # A page's own logo and cover, which this used to skip entirely: every
  # organization account was rendered with the installation's default icon, so a
  # client showed the vutuv logo beside a page that has had a picture all along.
  # The stand-in is the caller's, because it belongs to the *slot* rather than to
  # the page — a square icon is not a banner. The AI gate is not re-asked here:
  # an organization image is served through
  # `VutuvWeb.OrganizationImageController`, which resolves the token and asks it
  # per request.
  defp organization_image(nil, stand_in), do: stand_in

  defp organization_image(token, _stand_in),
    do: MastodonApi.main_url(OrganizationImage.token_url(token, "large"))

  # The cached picture of an account on another network (issue #1163), which
  # every surface of the website already shows and this one threw away: the
  # avatar was hardcoded to the installation's icon, so a Mastodon client
  # rendered the vutuv logo beside every remote author. `avatar_url/1` is the
  # one chokepoint that answers nil unless the AI gate cleared the file, so a
  # picture we may not show still falls back rather than leaking.
  #
  # The capability rides along because the proxy that serves these bytes asks
  # for a signed-in reader, and the thing fetching this URL is an image loader
  # with no cookie and no bearer — which is why naming the real picture, on its
  # own, only turned every remote face into a 404. See
  # `VutuvWeb.RemoteMediaToken`; the website keeps using the bare path and its
  # session.
  defp remote_avatar(%RemoteAccount{} = account) do
    case RemoteAccount.avatar_url(account) do
      path when is_binary(path) ->
        MastodonApi.main_url(path, RemoteMediaToken.avatar_query(account.id, account.avatar))

      nil ->
        fallback_avatar()
    end
  end

  defp note_account(%Note{account_id: id} = note) when is_binary(id) do
    case Fediverse.get_remote_account(id) do
      %RemoteAccount{} = remote_account -> account(remote_account)
      nil -> note_fallback_account(note)
    end
  end

  defp note_account(note), do: note_fallback_account(note)

  # The id the note's author carries as a status account, without paying for the
  # account record: the virtual `account_id` the note loader joins in already
  # says whether we hold one. What a parent link needs, and the only part of
  # `note_account/1` a *reference* to the note has to agree on.
  defp note_account_id(%Note{account_id: id}) when is_binary(id),
    do: account_id(%RemoteAccount{id: id})

  defp note_account_id(%Note{} = note), do: note_author_id(note)

  # The stand-in id for an author we hold no account row for. Derived from the
  # actor's own URI so the same stranger reads as the same account across a
  # page, and never as an id `/api/v1/accounts` would resolve.
  defp note_author_id(%Note{} = note),
    do:
      "remote-note-author-" <>
        (:crypto.hash(:sha256, note.actor_uri) |> Base.url_encode64(padding: false))

  defp note_fallback_account(note) do
    handle = Note.display_handle(note) |> String.trim_leading("@")
    username = handle |> String.split("@") |> hd()
    icon = fallback_avatar()

    base_account(%{
      id: note_author_id(note),
      username: username,
      acct: handle,
      display_name: note.display_name || username,
      created_at: timestamp(note.received_at),
      url: note.actor_uri,
      avatar: icon,
      group: false
    })
  end

  # The action bar's own figures, in Mastodon's names. `shown_counts/1` folds
  # in what other networks did with the same post, exactly as the website's
  # card does — a post has one like count, not one per world.
  defp engagement_fields(nil), do: %{}

  defp engagement_fields(engagement) do
    counts = Posts.shown_counts(engagement)

    %{
      favourites_count: counts.likes,
      reblogs_count: counts.reposts,
      replies_count: counts.replies,
      favourited: engagement.liked? == true,
      reblogged: engagement.reposted? == true,
      bookmarked: engagement.bookmarked? == true
    }
  end

  @doc """
  One tag in Mastodon's shape.

  `name` is the **slug**, not the display name: it is what a client puts back
  into `/api/v1/timelines/tag/:hashtag` and into a `#hashtag` it composes, so it
  has to be the spelling `/tags/:slug` answers to. `history` stays empty —
  vutuv keeps no per-day usage series, and an invented one would be read as
  fact.

  `following?` is the viewer's own subscription and defaults to false, which is
  the honest answer for a list rendered without a viewer (a status's own tags,
  an anonymous search). `featuring` is flat false until vutuv has a concept to
  fill it (issue #1592); the key stays because a 4.4 client reads it.
  """
  def tag(tag, following? \\ false)

  def tag(%Tag{} = tag, following?) do
    %{
      name: tag.slug,
      url: MastodonApi.main_url("/tags/" <> tag.slug),
      history: [],
      following: following?,
      featuring: false
    }
  end

  # The tags a client may act on: the ones the author CHOSE in the composer,
  # which are the chips the website prints under the card. A `#hashtag` written
  # into the body is deliberately not repeated here — it is already a link
  # inside `content`, filed apart from the chosen tags for exactly that reason
  # (`Vutuv.Posts.PostHashtag`), and listing it would print it twice in every
  # client that renders both.
  #
  # Preloaded on every reader that renders a post (`Posts.render_preloads/0`),
  # so this costs nothing; an unloaded association answers the empty list rather
  # than raising, the way the rest of this module treats one.
  defp status_tags(%Post{tags: tags}) when is_list(tags), do: Enum.map(tags, &tag/1)
  defp status_tags(_post), do: []

  # Who the post names with an `@handle`, from the batch `statuses/2` reads for
  # the whole page. Every status that reaches a client comes through there —
  # `one_status/2` wraps a single row into the same path — so an unbatched call
  # renders no mentions rather than firing a query per post, exactly the way
  # `status_tags/1` above treats an association nobody preloaded.
  defp status_mentions(_post, nil), do: []
  defp status_mentions(_post, mentioned), do: Enum.map(mentioned, &mention/1)

  # A client reads this to prefill a reply and to resolve the `@handle` links in
  # `content`, so `acct` has to be the handle exactly as the body spells it.
  #
  # The URL comes from `Vutuv.Identity.path/1`, the seam that owns where a
  # member-or-page actor links; a hand-built copy here is one more place the
  # next author kind would have to be remembered, and it could disagree with the
  # `url` of the very same account embedded beside it in the status.
  defp mention(mentioned) do
    handle = acct_handle(mentioned)

    %{
      id: mentioned.id,
      username: handle,
      acct: handle,
      url: profile_url(mentioned)
    }
  end

  defp profile_url(identity), do: MastodonApi.main_url(Identity.path(identity))

  # A page is addressed by its handle where it has one and by its slug
  # otherwise — the same fallback its canonical URL uses.
  defp acct_handle(%User{username: username}), do: username

  defp acct_handle(%Organization{} = organization),
    do: organization.username || organization.slug

  # `Posts.edited?/1` owns the rule, so the website card's "edited" hint and this
  # field are the same claim rather than two copies of one threshold.
  defp edited_at(%Post{} = post) do
    if Posts.edited?(post), do: timestamp(post.updated_at)
  end

  # vutuv has no visibility column: a post is public until it carries a denial,
  # and any denial at all closes it to anonymous readers (`PostDenial`). That
  # is not Mastodon's followers-only, but `private` is the honest neighbour —
  # it is the value that tells a client the post is **not** for redistribution,
  # so it stops offering boost on something its author narrowed. Calling every
  # post `public` told clients the opposite.
  defp visibility(post, engagement), do: audience(restricted?(post, engagement))

  # Read off the batched engagement where the page has one, so a timeline pays
  # no query per post for what it already knows.
  defp restricted?(_post, %{restricted?: restricted?}), do: restricted?
  defp restricted?(post, _no_engagement), do: Posts.restricted?(post)

  defp audience(true), do: "private"
  defp audience(_open), do: "public"

  # **The cached reply wins over the post underneath it** (issue #1641).
  # `Posts.create_remote_reply/3` files an answer to a reply from another
  # network as an ordinary local reply to the post that reply hangs under (issue
  # #1070), so the local parent is a level too high: a client threaded the
  # answer under the member's own post and labelled it "Replying to @member"
  # where it addresses a stranger. The website hangs it under the reply's card
  # for the same reason (`VutuvWeb.PostComponents`).
  #
  # Either way the id named is one this client can fetch, and nothing is named
  # that we hold no row for — an id no client can resolve is worse than none.
  defp reply_fields(_post, %Note{} = note, _context),
    do: %{in_reply_to_id: status_id(note), in_reply_to_account_id: note_account_id(note)}

  # The other half of the sidecar (issue #1165): a top-level vutuv post that
  # answers a followed account's post out there threads under the cached copy of
  # it, a status the same client can fetch. There is no local parent to prefer
  # here — the shape exists precisely because nothing of ours sits underneath.
  defp reply_fields(_post, %RemotePost{} = parent, context),
    do: remote_parent_fields(parent, context)

  defp reply_fields(post, _no_cached_parent, _context) do
    case Posts.reply_ref_state(post) do
      {:parent, %Post{} = parent} ->
        %{
          in_reply_to_id: status_id(parent),
          in_reply_to_account_id: account_id(Posts.author(parent))
        }

      _not_a_live_local_parent ->
        %{}
    end
  end

  # Names the local post a cached reply answers, read off `context.note_parents`
  # (`Posts.visible_posts_by_ids/2` — batched for the whole page and already
  # scoped to what `context.viewer` may see, the note's own visibility being no
  # proof that its narrower parent still is). Both author kinds ride that
  # preload, so the two ids are minted by the same pair the local-reply branch
  # above uses rather than read off the columns; `%{}` (both nil) when the post
  # is gone or not visible to this viewer.
  defp note_reply_fields(note, context) do
    case Map.get(context.note_parents, note.post_id) do
      %Post{} = parent ->
        %{
          in_reply_to_id: status_id(parent),
          in_reply_to_account_id: account_id(Posts.author(parent))
        }

      nil ->
        %{}
    end
  end

  # Names the cached parent post a stored reply continues, read off
  # `context.remote_parents` (`Fediverse.remote_parent_posts/1` — batched for
  # the whole page rather than a query per row).
  defp remote_post_reply_fields(
         %RemotePost{in_reply_to_uri: uri, remote_account_id: account_id},
         context
       ),
       do: remote_parent_fields(Map.get(context.remote_parents, {uri, account_id}), context)

  # The one place a cached parent becomes the two fields, for both callers
  # above. **Gated the same way `VutuvWeb.MastodonApi.Statuses.visible?/2` gates
  # the single-status read** (`context.readable_parents`): naming a
  # followers-only post hands a client an id that answers 404 — or worse,
  # silently confirms a restricted post exists — to every reader but the ones
  # this installation follows that account for. `%{}`, i.e. both nil, when the
  # parent is not (or no longer) held or may not be read: an id no client can
  # resolve or is refused for is worse than none, which is the issue's own rule.
  defp remote_parent_fields(%RemotePost{} = parent, context) do
    if MapSet.member?(context.readable_parents, parent.id) do
      %{
        in_reply_to_id: status_id(parent),
        in_reply_to_account_id: remote_account_id(parent)
      }
    else
      %{}
    end
  end

  defp remote_parent_fields(nil, _context), do: %{}

  # `account_id/1` where the account itself is loaded (`answered_objects/1`
  # selects it in), and the same spelling from the bare column where it is not
  # (`remote_parent_posts/1` reads ids, not accounts).
  defp remote_account_id(%RemotePost{remote_account: %RemoteAccount{} = account}),
    do: account_id(account)

  defp remote_account_id(%RemotePost{remote_account_id: id}), do: "remote-" <> id

  @doc """
  One freshly uploaded picture, for the media endpoints.

  A vutuv upload is never instantly usable: the AI image scan runs first and
  the row starts `pending`. Mastodon's own vocabulary already has that state —
  a `url` of `null` means "still processing, poll me" — so an unreleased image
  is rendered exactly that way rather than handing out a link to something no
  reader may see yet.
  """
  def media_attachment(%PostImage{} = image, viewer) do
    # A pending upload belongs to its uploader alone, so its URLs are as
    # credential-bound as a restricted post's (issue #1627) — and the loader
    # fetching the preview is the same session-less one.
    attachment = post_attachment(image, capability(image, viewer))

    if ImageScans.released?(image.moderation),
      do: attachment,
      else: %{attachment | url: nil, preview_url: nil}
  end

  @doc "Whether the scan has finished with this picture, either way."
  def media_ready?(%PostImage{} = image), do: ImageScans.released?(image.moderation)

  # **A body is served away from home too, so its own URLs have to travel**
  # (issue #1647). The attachments were fixed first, but a client renders
  # `content` as HTML and every URL the website's renderer writes into it is
  # root-relative — an inline photo, an `@mention`, a `#hashtag` — so none of
  # them resolves in an app, on a public post as much as a restricted one. The
  # pictures take the same capability their attachments take, and the whole
  # fragment is then absolutized against the main domain, the way the RSS item
  # and the federated Note already are.
  #
  # `released_images/1` and not every loaded picture, the same set the
  # attachments name: a client has no placecard for one still in the AI gate,
  # so inlining it would only be a second broken image — and it would be handed
  # a capability the proxy is going to refuse anyway. It is also what keeps a
  # missing preload from costing the **words**: it answers `[]` for an unloaded
  # association where `post.images || []` would hand `render_post/3` a
  # `NotLoaded`, fail its `is_list` guard and silently render a status with no
  # text at all (`Vutuv.Search` does not preload, and the search endpoint duly
  # served blank posts once).
  defp content_html(post, photo_viewer) do
    post.body
    |> Markdown.render_post(Posts.released_images(post),
      image_query: &capability(&1, photo_viewer)
    )
    |> safe_html()
    |> Markdown.absolutize_html(main_base())
  end

  # The same for a cached post or reply. It carries no picture of ours, but
  # `render_remote/1` still writes our `#hashtag` and local-`@mention` links
  # root-relative, and those resolve in an app no better than an image URL does.
  defp remote_content_html(text),
    do: text |> Kernel.||("") |> Markdown.render_remote() |> Markdown.absolutize_html(main_base())

  # Every URL a client is handed points at the main domain, never at the API
  # subdomain it is talking to: that is where the pictures and the profiles are.
  defp main_base, do: MastodonApi.main_url("")

  # The capability is minted only where a bare image loader would otherwise be
  # turned away: a post its author narrowed. A public post's photo stays a plain
  # URL — it needs no credential, and a bearer URL that buys nothing is one more
  # thing that can be shared. One per photo, since the token names the picture
  # it opens.
  defp media_attachments(post, viewer) do
    post |> Posts.released_images() |> Enum.map(&post_attachment(&1, capability(&1, viewer)))
  end

  defp post_attachment(%PostImage{} = image, query) do
    attachment(image, image_url(image, "large", query), image_url(image, "feed", query))
  end

  # Mastodon's attachment entity, and the one place its shape is written: the
  # two kinds of picture here differ in where their bytes come from, never in
  # what a client is told about them.
  defp attachment(image, url, preview_url, remote_url \\ nil) do
    %{
      id: image.id,
      type: "image",
      url: url,
      preview_url: preview_url,
      remote_url: remote_url,
      preview_remote_url: nil,
      text_url: nil,
      meta: %{original: %{width: image.width, height: image.height}},
      description: image.alt || "",
      blurhash: nil
    }
  end

  # `nil` for anything but a member: `Vutuv.Posts.image_visible_to?/2` and
  # `Vutuv.Fediverse.remote_image_visible?/2` both answer a `%User{}` and
  # nothing else, so a capability naming a page identity would be one the proxy
  # could never honour. Those readers keep today's plain URL, which is right for
  # every public picture and a broken one for the rest — a narrower gap than
  # handing out a credential that does not work.
  defp capability(%PostImage{token: token}, %User{id: user_id}),
    do: RemoteMediaToken.post_image_query(token, user_id)

  defp capability(%RemoteImage{} = image, %User{id: user_id}),
    do: RemoteMediaToken.remote_image_query(image.id, image.file, user_id)

  defp capability(_image, _viewer), do: nil

  # One version's URL, carrying the capability where there is one. `PostImage.url/2`
  # may already end in the crop buster's own `?v=…`, so the capability is appended
  # to that query rather than replacing it.
  defp image_url(%PostImage{} = image, version, query) do
    image
    |> PostImage.url(version)
    |> Markdown.append_query(query)
    |> MastodonApi.main_url()
  end

  # The photographs on a post from another network (issue #1626). They exist,
  # they are cached and the website renders them — the adapter simply never
  # named them, so the same post showed its picture in a browser and none in an
  # app. Every URL is the authorizing proxy's, never the origin's: the AI gate,
  # the stored-file whitelist and the post's audience are all re-asked there. A
  # client that follows `remote_url` instead reaches the origin server directly,
  # which is its decision to make and not one we make for the reader.
  defp remote_attachments(%RemotePost{} = post, context) do
    context.remote_images
    |> Map.get(post.id, [])
    |> Enum.filter(&RemoteImage.released?/1)
    |> Enum.map(&remote_attachment(&1, context.viewer))
  end

  defp remote_attachment(%RemoteImage{} = image, viewer) do
    # One stored version, so the preview and the picture are the same file — a
    # derived copy is all this installation keeps of somebody else's photograph.
    url =
      MastodonApi.main_url(
        RemoteMedia.post_image_url(image.id, image.file),
        capability(image, viewer)
      )

    attachment(image, url, url, image.source_uri)
  end

  defp safe_html(value), do: value |> Safe.to_iodata() |> IO.iodata_to_binary()

  @doc """
  A time in Mastodon's shape, and the **one** place that decides it.

  Public because notifications render their own rows: the same conversion
  existed twice, which is how one of them kept second precision after the other
  was fixed. See the comment below for why the milliseconds matter.
  """
  def timestamp(value)

  # **Milliseconds are not decoration.** Mastodon stamps every time as
  # `2019-11-26T22:37:36.000Z`, always with three fractional digits, and the
  # clients are written against exactly that: Apple's `ISO8601DateFormatter`
  # with `.withFractionalSeconds` — what an Ivory or Ice Cubes builds once and
  # reuses — **fails outright** on a string without them, and a client that
  # cannot parse a date falls back to "now". So every post in the timeline
  # carried the moment the account was added to the app, all with the same
  # relative time, which is what a member reported. Second precision is enough
  # for us; printing it in Mastodon's shape is what makes it readable.
  def timestamp(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> timestamp()

  def timestamp(%DateTime{} = value) do
    value
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.truncate(:millisecond)
    |> Map.put(:microsecond, {elem(value.microsecond, 0), 3})
    |> DateTime.to_iso8601()
  end

  # Not every caller hands over a fully loaded row: `Vutuv.Search` selects the
  # few columns a result list needs, so `inserted_at` can be absent. Raising
  # over a missing display timestamp would be the wrong trade, and there is a
  # better answer than nil — the id is a UUIDv7 and carries its own creation
  # time.
  def timestamp(_missing), do: nil

  defp created_at(%{inserted_at: at}, _id) when not is_nil(at), do: timestamp(at)
  defp created_at(_record, id), do: timestamp(UUIDv7.timestamp(id))
end
