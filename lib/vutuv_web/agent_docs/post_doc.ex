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

  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostImage
  alias Vutuv.Posts.PostReview
  alias VutuvWeb.AgentDocs
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

    AgentDocs.doc_meta("post", Posts.path(post), noindex: noindex?, noai: noai?)
    |> Map.merge(%{
      id: post.id,
      title: "#{UserHelpers.full_name(author)} · #{Date.to_iso8601(post.published_on)}",
      description: AgentDocs.excerpt(post.body),
      author: AgentDocs.person_ref(author),
      published_on: post.published_on,
      body_markdown: post.body,
      # The structured book/film review riding on the post (nil for ordinary
      # posts) — what the HTML review card shows.
      review: review_entry(post.review),
      tags: Enum.map(post.tags, & &1.name),
      # Anonymous public view: images still in (or deleted by) AI moderation
      # never appear here.
      images: post |> Posts.released_images() |> Enum.map(&image_entry/1),
      in_reply_to: in_reply_to(post),
      # The anonymous doc lists only anonymous-visible replies; count the loaded
      # rows so it matches exactly. (Posts.reply_count/1 now also excludes
      # frozen / denied replies (issue #774), but counting `replies` here avoids
      # a second query and can never drift from the list.)
      reply_count: length(replies),
      replies: Enum.map(replies, &reply_entry/1),
      # The whole conversation the HTML permalink renders (issue #1006), in
      # the same reading order (the reply tree depth-first, issue #1027);
      # every entry carries its parent pointer and its nesting depth, so the
      # tree is recoverable without re-deriving it. `replies` above stays the
      # one-level list for API consumers that relied on it.
      thread: thread_entries(thread),
      thread_truncated: thread_truncated?,
      # The public engagement counters the HTML action bar shows to everyone.
      like_count: engagement.likes,
      repost_count: engagement.reposts,
      bookmark_count: engagement.bookmarks
    })
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

  @doc """
  One timeline entry (`%{post:, reposted_by:, reposters:}`) as a compact doc
  map: id, the post URL, author + repost names, publish date and a one-line
  excerpt. Shared by the author archive (above) and the personalized feed
  (`VutuvWeb.AgentDocs.FeedDoc`), so the two render a post the same way.

  `reposters` is every reposter behind the entry (the feed carries the whole
  follow-scoped roster; the archive a single one), newest first, as names —
  `reposted_by` stays the newest for callers that want just the one name.
  """
  def timeline_entry(%{post: post} = entry) do
    reposters = entry[:reposters] || List.wrap(entry[:reposted_by])

    %{
      id: post.id,
      url: AgentDocs.abs_url(Posts.path(post)),
      author: UserHelpers.full_name(post.user),
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
    authors = Map.new(posts, &{&1.id, UserHelpers.full_name(&1.user)})
    depths = thread_depths(posts)

    Enum.map(posts, fn post ->
      parent_id = post.reply_ref && post.reply_ref.parent_post_id

      %{
        id: post.id,
        url: AgentDocs.abs_url(Posts.path(post)),
        author: UserHelpers.full_name(post.user),
        author_username: post.user.username,
        published_on: post.published_on,
        body_markdown: post.body,
        depth: depths[post.id],
        in_reply_to_id: parent_id,
        in_reply_to_author: parent_id && authors[parent_id]
      }
    end)
  end

  # One pass suffices: reading order puts every post after the one it answers,
  # so its parent's depth is already known. A post whose parent is not in the
  # thread (the root, or a chain broken by a deletion) starts at 0.
  defp thread_depths(posts) do
    Enum.reduce(posts, %{}, fn post, depths ->
      parent_id = post.reply_ref && post.reply_ref.parent_post_id
      Map.put(depths, post.id, (parent_id && depths[parent_id] && depths[parent_id] + 1) || 0)
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

  defp image_entry(%PostImage{} = image) do
    %{
      alt: image.alt,
      width: image.width,
      height: image.height,
      urls: image |> PostImage.urls() |> Map.new(fn {k, v} -> {k, absolutize(v)} end)
    }
  end

  defp absolutize("/" <> _ = path), do: AgentDocs.abs_url(path)
  defp absolutize(url), do: url

  defp in_reply_to(post) do
    case Posts.reply_ref_state(post) do
      {:parent, parent} ->
        %{
          url: AgentDocs.abs_url(Posts.path(parent)),
          author: UserHelpers.full_name(parent.user)
        }

      {:author_only, author} ->
        %{url: nil, author: UserHelpers.full_name(author)}

      :gone ->
        %{url: nil, author: nil}

      nil ->
        nil
    end
  end
end
