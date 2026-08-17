defmodule VutuvWeb.AgentDocs.PostDoc do
  @moduledoc """
  The post permalink (`/:slug/posts/:id`) and the author archive
  (`/:slug/posts[...]`) as data maps for the agent formats. Anonymous view
  only: the controller checks `Posts.visible_to?(post, nil)` before building,
  and the archive is queried with `viewer = nil`.

  Changed what the post pages show? Update these builders too — the drift
  test (`agent_docs_drift_test.exs`) will remind you.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Handle
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemoteImage
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.Posts
  alias Vutuv.Posts.PhotoLicense
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostImage
  alias Vutuv.Posts.PostRemoteReply
  alias Vutuv.Posts.PostReview
  alias Vutuv.Profiles.VerifiedLinks
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.Markdown
  alias VutuvWeb.UserHelpers

  @doc """
  The robots axes of a post page as `{noindex?, noai?}`: a restriction
  noindexes the page and keeps it from AI page-level, and the author's
  `noai?` extends their AI opt-out to all their posts. The one derivation
  behind the HTML permalink's headers (`PostController`) and the doc's,
  so the two cannot disagree.
  """
  def robots_axes(author, restricted?), do: {restricted?, restricted? or author.noai?}

  @doc """
  The permalink page: the post itself plus its visible replies. Anonymous
  by default; `viewer:` switches the reply list (and its count) to what
  that user sees — the authenticated `/api/2.0` reads. Never pass a viewer
  for the extension URLs, they must stay cache-safe.
  """
  def build(author, %Post{} = post, opts \\ []) do
    viewer = Keyword.get(opts, :viewer)
    replies = Posts.list_replies(post, viewer)
    %{posts: thread, truncated?: thread_truncated?} = Posts.list_thread(post, viewer)
    {noindex?, noai?} = robots_axes(author, Posts.restricted?(post))
    engagement = Posts.engagement_counts(post.id)
    counts = Posts.shown_counts(engagement)

    # The replies written on other networks that the HTML thread weaves in
    # (issue #1069). **Public ones only, on every path** — note the hardcoded
    # `nil` viewer: `build/3` also serves the authenticated `/api/2.0` reads,
    # and a reply addressed to the member alone (issue #1071) must not leave
    # the page it was sent to, not through an API and not through a `.json`
    # sibling. The member reads their private replies on the post itself.
    remote_replies = [post.id] |> Fediverse.list_notes(nil) |> remote_entries(post.id)

    AgentDocs.doc_meta("post", Posts.path(post), noindex: noindex?, noai: noai?)
    |> Map.merge(%{
      id: post.id,
      title: "#{UserHelpers.full_name(author)} · #{Date.to_iso8601(post.published_on)}",
      description: AgentDocs.excerpt(post.body),
      author: AgentDocs.person_ref(author),
      published_on: post.published_on,
      body_markdown: post.body,
      # The links in that body pointing at a webpage the author has PROVED is
      # their own (issue #1246). The HTML page marks them with the emerald ✓,
      # which a `.md`/`.json` reader cannot see, so the fact travels as data:
      # the proven address, the method behind it, and what the proof covers.
      verified_author_links: verified_author_links(author, post.body),
      # The structured book/film review riding on the post (nil for ordinary
      # posts) — what the HTML review card shows.
      review: review_entry(post.review),
      tags: Enum.map(post.tags, & &1.name),
      # Anonymous public view: images still in (or deleted by) AI moderation
      # never appear here.
      images: post |> Posts.released_images() |> Enum.map(&image_entry/1),
      # The licence the photos are published under (issue #1104), as both the
      # human label and the SPDX identifier — a machine deciding whether it may
      # reuse a picture should not have to parse a translated sentence.
      license: license_entry(post),
      in_reply_to: in_reply_to(post),
      # Every reply the page counts, from both worlds — the figure the HTML
      # reply button now shows (a remote reply is a reply). Counted off the two
      # loaded lists rather than re-queried, so the number and the entries below
      # it can never drift: `replies` holds the anonymous-visible vutuv ones
      # (Posts.reply_count/1 excludes frozen / denied replies since issue #774)
      # and `fediverse_replies` the public remote ones.
      reply_count: length(replies) + length(remote_replies),
      replies: Enum.map(replies, &reply_entry/1),
      # The whole conversation the HTML permalink renders (issue #1006), in
      # the same reading order (the reply tree depth-first, issue #1027);
      # every entry carries its parent pointer and its nesting depth, so the
      # tree is recoverable without re-deriving it. `replies` above stays the
      # one-level list for API consumers that relied on it.
      thread: thread_entries(thread),
      thread_truncated: thread_truncated?,
      # The public engagement counters the HTML action bar shows to everyone —
      # vutuv's own tally **and** what other networks did, in one figure each,
      # exactly as the buttons print them (`Posts.shown_counts/1`).
      like_count: counts.likes,
      # ...and **who** liked it (issue #1233), the same members the HTML page
      # names under the count, newest first and capped the same way — the count
      # above stays the true total.
      #
      # Attributed members only, on every path: note the hardcoded anonymous
      # call. The page shows a member who opted out of being named to the
      # post's **author** (they were named in the like notification at the
      # time), and the reader of a doc is never that author — not through a
      # `.md` sibling and not through the authenticated `/api/2.0`, which
      # `build/3` also serves.
      likers: Enum.map(Posts.post_likers(post.id), &AgentDocs.person_ref/1),
      repost_count: counts.reposts,
      bookmark_count: engagement.bookmarks,
      # ...and the breakdown the card's "from other networks" panel shows when
      # you open it, so a machine can tell the two worlds apart again: how many
      # of the likes and reposts above arrived over ActivityPub (issue #1068).
      # Nothing here is additional to the counts, it is part of them.
      fediverse_like_count: engagement.fediverse_likes,
      fediverse_repost_count: engagement.fediverse_reposts,
      fediverse_reaction_count: Posts.fediverse_reaction_count(engagement),
      # ...and the accounts behind the newest few of them, exactly the chips the
      # HTML panel names — same rows, same cap, so the two cannot drift. The
      # counts above stay the true totals.
      fediverse_reactions: reaction_entries(engagement),
      fediverse_reply_count: engagement.fediverse_replies,
      fediverse_replies: remote_replies
    })
  end

  @doc """
  A post published in an organization's name (issue #1334).

  A smaller document than `build/3`, because the page it describes is smaller:
  an organization post carries no audience, so there is nothing to say about
  restriction, and the member who pressed publish is **not** in this document
  and must never be — that split is the whole point of `acting_user_id`, and a
  `.json` sibling that leaked it would undo it. Everything else means exactly
  what it does on a member's post, so a reader can treat the two alike.

  **The conversation is one of those things** (issue #1336). This used to say a
  page's post could not be answered and therefore had no reply list and no
  thread, which stopped being true the moment answering was allowed — and the
  remote half was never true at all, since the HTML page has rendered replies
  from other networks since #1334. That is the drift `agent_docs_drift_test.exs`
  exists to catch and does not cover here, so it has to be watched by hand: the
  permalink hosts the same `VutuvWeb.PostLive.Thread` the member permalink does,
  and these fields are what that thread shows.

  Anonymous throughout, like every doc here — `nil` viewer to `list_replies/2`,
  `list_thread/2` and `list_notes/2` alike, so a reply addressed to the page
  alone (issue #1071) never leaves the page it was sent to.
  """
  def build_organization_post(%Organization{} = organization, %Post{} = post) do
    engagement = Posts.engagement_counts(post.id)
    counts = Posts.shown_counts(engagement)
    replies = Posts.list_replies(post, nil)
    %{posts: thread, truncated?: thread_truncated?} = Posts.list_thread(post, nil)
    remote_replies = [post.id] |> Fediverse.list_notes(nil) |> remote_entries(post.id)

    AgentDocs.doc_meta("organization_post", Posts.path(post),
      noindex: not organization.seo?,
      noai: not organization.geo?
    )
    |> Map.merge(%{
      id: post.id,
      title: "#{organization.name} · #{Date.to_iso8601(post.published_on)}",
      description: AgentDocs.excerpt(post.body),
      author: organization_ref(organization),
      published_on: post.published_on,
      body_markdown: post.body,
      review: review_entry(post.review),
      tags: Enum.map(post.tags, & &1.name),
      images: post |> Posts.released_images() |> Enum.map(&image_entry/1),
      license: license_entry(post),
      # Counted off the two loaded lists rather than re-queried, the same way
      # `build/3` does it, so the figure and the entries under it cannot drift.
      reply_count: length(replies) + length(remote_replies),
      replies: Enum.map(replies, &reply_entry/1),
      thread: thread_entries(thread),
      thread_truncated: thread_truncated?,
      like_count: counts.likes,
      likers: Enum.map(Posts.post_likers(post.id), &AgentDocs.person_ref/1),
      repost_count: counts.reposts,
      bookmark_count: engagement.bookmarks,
      fediverse_like_count: engagement.fediverse_likes,
      fediverse_repost_count: engagement.fediverse_reposts,
      fediverse_reaction_count: Posts.fediverse_reaction_count(engagement),
      fediverse_reactions: reaction_entries(engagement),
      fediverse_reply_count: engagement.fediverse_replies,
      fediverse_replies: remote_replies
    })
  end

  # The organization's own reference, the counterpart of `AgentDocs.person_ref/1`.
  # `canonical_path/1` prefers the page's opt-in root handle, so the URL here is
  # the one the page answers to rather than the slug form the post lives under.
  defp organization_ref(%Organization{} = organization) do
    %{
      name: organization.name,
      slug: organization.slug,
      url: AgentDocs.abs_url(Organizations.canonical_path(organization))
    }
  end

  @doc """
  The archive page: one offset page of the author's timeline (posts and
  reposts), whole or scoped to a year / month / day (`period_label`).
  `path` is the extension-free request path, so the doc describes exactly
  the page that was asked for (including the period segments).
  """
  def build_archive(author, path, entries, total, period_label) do
    AgentDocs.doc_meta("post_archive", path, noai: author.noai?)
    |> Map.merge(%{
      title:
        "#{UserHelpers.full_name(author)} · #{gettext("Posts")}" <> period_suffix(period_label),
      description: gettext("Post archive of %{name}", name: UserHelpers.full_name(author)),
      author: AgentDocs.person_ref(author),
      period: period_label,
      total: total,
      posts: Enum.map(entries, &timeline_entry/1)
    })
  end

  defp period_suffix(nil), do: ""
  defp period_suffix(label), do: " · #{label}"

  # The links in the body that point at a webpage the author has proved is
  # their own (issue #1246) — the emerald ✓ the HTML page draws, as data.
  #
  # The `http` test is the whole guard the query needs: nothing without a
  # scheme in it can name a proven page, so an ordinary post pays nothing.
  defp verified_author_links(author, body) do
    if String.contains?(body, "http") do
      body
      |> Markdown.verified_author_links(VerifiedLinks.load(author))
      |> Enum.map(&verified_link_entry/1)
    else
      []
    end
  end

  # `address` is the shortest honest reading of the proof and `scope` says how
  # far it reaches: `"host"` when the member controls the whole host (a DNS /
  # well-known proof, or a rel=me back-link on the front page), `"page"` when
  # the rel=me proof covers exactly this one URL and nothing beside it.
  defp verified_link_entry(link) do
    %{
      url: link.value,
      address: VerifiedLinks.address(link),
      verified_method: link.verification_method,
      scope: VerifiedLinks.scope(link)
    }
  end

  @doc """
  One timeline entry (`%{post:, reposted_by:, reposters:}`) as a compact doc
  map: id, the post URL, author + repost names, publish date and a one-line
  excerpt. Shared by the author archive (above) and the personalized feed
  (`VutuvWeb.AgentDocs.FeedDoc`), so the two render a post the same way.

  `reposters` is every reposter behind the entry (the feed carries the whole
  follow-scoped roster; the archive a single one), newest first, as names —
  `reposted_by` stays the newest for callers that want just the one name.
  """
  def timeline_entry(%{remote_post: %RemotePost{} = remote} = entry) do
    account = remote.remote_account

    %{
      id: remote.id,
      # The origin, not a vutuv URL: the post lives on its own server and we
      # serve no page for it.
      url: RemotePost.origin(remote),
      author: RemoteAccount.label(account),
      published_on: DateTime.to_date(remote.published_at),
      excerpt: AgentDocs.excerpt(remote.content_text),
      # How many pictures the entry carries (issue #1163). A post from another
      # network can be a photograph and nothing else, and its stored body is
      # then genuinely empty — so without this an agent would read a wordless
      # photo post as an entry with no content at all. The renderers turn the
      # count into a phrase in the reader's own language.
      pictures: Enum.count(entry[:images] || [], &RemoteImage.released?/1),
      reposted_by: nil,
      reposters: [],
      # What the HTML card says in its footer, as a fact rather than a skin: an
      # agent reading this timeline has to be able to tell a member's own post
      # from somebody else's, published elsewhere and cached here.
      network: "fediverse",
      account: RemoteAccount.display_handle(account)
    }
  end

  def timeline_entry(%{post: post} = entry) do
    reposters = entry[:reposters] || List.wrap(entry[:reposted_by])

    %{
      id: post.id,
      url: AgentDocs.abs_url(Posts.path(post)),
      # Whichever kind of author the post has (issue #1334) — the reposters
      # below stay members, since only a member can repost.
      # The name the entry is signed with: a page by its own name, the member
      # who published for it stays internal, exactly as on the HTML card.
      author: UserHelpers.author_name(post),
      published_on: post.published_on,
      excerpt: AgentDocs.excerpt(post.body),
      reposted_by: entry[:reposted_by] && UserHelpers.full_name(entry[:reposted_by]),
      reposters: Enum.map(reposters, &UserHelpers.full_name/1)
    }
  end

  # The conversation entries, in `Posts.list_thread/3` reading order.
  # `in_reply_to_author` resolves only inside the thread (a deleted or
  # invisible parent stays nil), so the markdown/text renderers can name a
  # branch's parent without another lookup, and `depth` is how deep the entry
  # hangs in the thread — the nesting the HTML page draws, as a number the
  # other formats can indent by.
  defp thread_entries(posts) do
    # `UserHelpers.author_name/1`, not `full_name/1`: a conversation can hold a
    # post published in a page's name (issue #1336 — a member may answer one),
    # and `full_name/1` raised on it, so the `.md`/`.txt`/`.json`/`.xml` sibling
    # of every answer to a page's post was a 500 while the HTML rendered fine.
    authors = Map.new(posts, &{&1.id, UserHelpers.author_name(&1)})
    depths = thread_depths(posts)

    Enum.map(posts, fn post ->
      parent_id = post.reply_ref && post.reply_ref.parent_post_id

      %{
        id: post.id,
        url: AgentDocs.abs_url(Posts.path(post)),
        author: UserHelpers.author_name(post),
        # A page's handle is optional (`/organizations/:slug` always works), so
        # nil here is the honest answer rather than a gap — `author` above names
        # it either way.
        author_username: author_username(Posts.author(post)),
        published_on: post.published_on,
        body_markdown: post.body,
        depth: depths[post.id],
        in_reply_to_id: parent_id,
        in_reply_to_author: parent_id && authors[parent_id]
      }
    end)
  end

  # The handle beside the name, for whichever kind of author the post has. A page
  # may never have claimed one, and nil is then the honest answer.
  defp author_username(%Organization{username: username}), do: username
  defp author_username(%User{username: username}), do: username

  # One pass suffices: reading order puts every post after the one it answers,
  # so its parent's depth is already known. A post whose parent is not in the
  # thread (the root, or a chain broken by a deletion) starts at 0.
  defp thread_depths(posts) do
    Enum.reduce(posts, %{}, fn post, depths ->
      parent_id = post.reply_ref && post.reply_ref.parent_post_id
      Map.put(depths, post.id, (parent_id && depths[parent_id] && depths[parent_id] + 1) || 0)
    end)
  end

  # One reply from another network as a doc entry: who wrote it in the
  # `@handle@host` form the HTML card shows, where the original lives, and the
  # plain text. No avatar (there is none stored) and no actor URI beyond the
  # public account link.
  defp remote_entries(by_post, post_id) do
    by_post
    |> Map.get(post_id, [])
    |> Enum.map(fn note ->
      %{
        handle: Note.display_handle(note),
        author: Note.label(note),
        network: Note.host(note.actor_uri),
        url: Note.origin(note),
        received_at: note.received_at,
        content_warning: note.summary,
        text: note.content_text
      }
    end)
  end

  # One reaction from another network as a doc entry: the account address in
  # both notations and what they did. That is the entire stored row — there is
  # no name, no avatar and no text to add.
  defp reaction_entries(engagement) do
    engagement
    |> Map.get(:fediverse_reaction_actors, [])
    |> List.wrap()
    |> Enum.map(fn row ->
      %{
        handle: Handle.display(row["handle"], row["actor_uri"]),
        network: Handle.host(row["actor_uri"]),
        url: row["actor_uri"],
        kind: row["kind"],
        received_at: row["received_at"]
      }
    end)
  end

  defp reply_entry(%Post{} = reply) do
    %{
      url: AgentDocs.abs_url(Posts.path(reply)),
      author: UserHelpers.full_name(reply.user),
      author_username: reply.user.username,
      published_on: reply.published_on,
      body_markdown: reply.body
    }
  end

  defp review_entry(%PostReview{} = review) do
    %{
      kind: review.kind,
      identifier: review.identifier,
      title: review.title,
      creator: review.creator,
      year: review.year,
      medium: review.medium,
      pages: review.pages,
      publisher: review.publisher,
      duration_minutes: review.duration_minutes,
      # nil = the review's own edition; an ISBN = the audio edition the time
      # was read from, so a machine reader can tell exact from approximate.
      duration_isbn: review.duration_isbn,
      link: PostReview.amazon_url(review) || PostReview.imdb_url(review)
    }
  end

  defp review_entry(_other), do: nil

  # Only for a post that actually has photos: a licence line on a text post
  # describes nothing.
  defp license_entry(%Post{images: images} = post) when is_list(images) and images != [] do
    %{
      id: post.license,
      name: PhotoLicense.label(post.license),
      spdx: PhotoLicense.spdx(post.license),
      url: PhotoLicense.url(post.license)
    }
  end

  defp license_entry(_post), do: nil

  # A photo as the agent formats publish it (issue #1104). Everything the HTML
  # page shows a visitor is here — caption, the camera facts *when the author
  # switched them on*, and the download URL *when the author opened it* — and
  # nothing it does not: a photo whose camera panel is off carries no camera
  # keys at all, rather than a set of nulls that would tell a reader the facts
  # exist and are being withheld.
  defp image_entry(%PostImage{} = image) do
    %{
      alt: image.alt,
      caption: image.caption,
      width: image.width,
      height: image.height,
      urls: image |> PostImage.urls() |> Map.new(fn {k, v} -> {k, absolutize(v)} end),
      download_url: image |> PostImage.download_url() |> absolutize_maybe()
    }
    |> Map.merge(camera_entry(image))
  end

  defp camera_entry(%PostImage{} = image) do
    if PostImage.show_camera_info?(image) do
      %{
        camera: image.camera,
        lens: image.lens,
        focal_length_mm: image.focal_length,
        aperture: image.aperture,
        shutter: image.shutter,
        iso: image.iso,
        taken_at: image.taken_at
      }
    else
      %{}
    end
  end

  defp absolutize_maybe(nil), do: nil
  defp absolutize_maybe(url), do: absolutize(url)

  defp absolutize("/" <> _ = path), do: AgentDocs.abs_url(path)
  defp absolutize(url), do: url

  defp in_reply_to(post) do
    case Posts.reply_ref_state(post) do
      # `author_name/1` on both, not `full_name/1`: the post answered may have
      # been published in a page's name (issue #1336), and `full_name/1` has no
      # clause for a page — it would raise on the `.md`/`.json` sibling of every
      # answer to one, i.e. a 500 where the HTML card renders fine.
      {:parent, parent} ->
        %{
          url: AgentDocs.abs_url(Posts.path(parent)),
          author: UserHelpers.author_name(parent)
        }

      {:author_only, author} ->
        %{url: nil, author: UserHelpers.author_name(author)}

      :gone ->
        %{url: nil, author: nil}

      nil ->
        # Not a reply here, but it may answer a post on another network (issue
        # #1165): the HTML card says so, so the agent formats must too, or a
        # `.md`/`.json` sibling reads as a post with no context while the page
        # names who it answers. The origin URI is the authoritative thing to
        # point at — that answer threads under it over there.
        remote_in_reply_to(post)
    end
  end

  defp remote_in_reply_to(%{remote_reply_ref: %PostRemoteReply{} = ref})
       when is_binary(ref.handle),
       do: %{url: ref.in_reply_to_uri, author: ref.handle, network: "fediverse"}

  defp remote_in_reply_to(_post), do: nil
end
