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
    replies = Posts.list_replies(post, Keyword.get(opts, :viewer))
    {noindex?, noai?} = robots_axes(author, Posts.restricted?(post))

    AgentDocs.doc_meta("post", Posts.path(post), noindex: noindex?, noai: noai?)
    |> Map.merge(%{
      id: post.id,
      title: "#{UserHelpers.full_name(author)} · #{Date.to_iso8601(post.published_on)}",
      description: AgentDocs.excerpt(post.body),
      author: AgentDocs.person_ref(author),
      published_on: post.published_on,
      body_markdown: post.body,
      tags: Enum.map(post.tags, & &1.name),
      images: Enum.map(post.images, &image_entry/1),
      in_reply_to: in_reply_to(post),
      # The anonymous doc lists only anonymous-visible replies; count the loaded
      # rows so it matches exactly. (Posts.reply_count/1 now also excludes
      # frozen / denied replies (issue #774), but counting `replies` here avoids
      # a second query and can never drift from the list.)
      reply_count: length(replies),
      replies: Enum.map(replies, &reply_entry/1)
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
      posts: Enum.map(entries, &entry/1)
    })
  end

  defp period_suffix(nil), do: ""
  defp period_suffix(label), do: " · #{label}"

  defp entry(%{post: post, reposted_by: reposted_by}) do
    %{
      id: post.id,
      url: AgentDocs.abs_url(Posts.path(post)),
      author: UserHelpers.full_name(post.user),
      published_on: post.published_on,
      excerpt: AgentDocs.excerpt(post.body),
      reposted_by: reposted_by && UserHelpers.full_name(reposted_by)
    }
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
