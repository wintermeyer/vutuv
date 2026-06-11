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
  alias Vutuv.Posts.PostReply
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.UserHelpers

  @doc """
  The permalink page: the post itself plus its visible replies. Anonymous
  by default; `viewer:` switches the reply list (and its count) to what
  that user sees — the authenticated `/api/2.0` reads. Never pass a viewer
  for the extension URLs, they must stay cache-safe.
  """
  def build(author, %Post{} = post, opts \\ []) do
    replies = Posts.list_replies(post, Keyword.get(opts, :viewer))

    AgentDocs.doc_meta("post", Posts.path(post), noindex: Posts.restricted?(post))
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
      # The anonymous doc lists only anonymous-visible replies, so the count
      # must match — Posts.reply_count/1 counts restricted replies too and
      # would over-advertise.
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
    AgentDocs.doc_meta("post_archive", path)
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
      author_slug: reply.user.active_slug,
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

  defp in_reply_to(%Post{reply_ref: %PostReply{} = ref}) do
    cond do
      match?(%Post{}, ref.parent_post) ->
        %{
          url: AgentDocs.abs_url(Posts.path(ref.parent_post)),
          author: UserHelpers.full_name(ref.parent_post.user)
        }

      match?(%Vutuv.Accounts.User{}, ref.parent_author) ->
        %{url: nil, author: UserHelpers.full_name(ref.parent_author)}

      true ->
        %{url: nil, author: nil}
    end
  end

  defp in_reply_to(_post), do: nil
end
