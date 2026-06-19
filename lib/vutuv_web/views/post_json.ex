defmodule VutuvWeb.PostJSON do
  @moduledoc """
  API-shaped serialization of a post — the single source for any future
  `/api` endpoint and a contract test target today, so the internal data
  structure stays honest.

  The `audience` field is viewer-dependent: the full deny array is the
  author's private configuration and is serialized **only** for the author;
  everyone else sees at most `%{restricted: true}`. Presets do not exist at
  this level — they are UI sugar over the deny array.
  """

  alias Vutuv.Accounts.User
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostImage
  alias Vutuv.Posts.PostReply

  @doc "Serializes a preloaded post for `viewer` (a `%User{}` or `nil`)."
  def post(%Post{} = post, viewer) do
    %{
      id: post.id,
      url: VutuvWeb.Endpoint.url() <> Posts.path(post),
      author: author_ref(post.user),
      body_markdown: post.body,
      body_html:
        post.body
        |> VutuvWeb.Markdown.render_post(post.images)
        |> Phoenix.HTML.safe_to_string(),
      published_at: post.inserted_at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601(),
      tags: Enum.map(post.tags, & &1.name),
      images: Enum.map(post.images, &image/1),
      reply_count: Posts.reply_count(post.id),
      in_reply_to: in_reply_to(post),
      audience: audience(post, viewer)
    }
  end

  # The reply reference mirrors the card banner's three states: a live
  # parent, a deleted post whose author still exists, or nothing nameable
  # once the account is gone too. `nil` when the post is not a reply.
  defp in_reply_to(%Post{reply_ref: %PostReply{} = ref}) do
    cond do
      match?(%Post{}, ref.parent_post) ->
        %{
          post_id: ref.parent_post.id,
          url: VutuvWeb.Endpoint.url() <> Posts.path(ref.parent_post),
          author: author_ref(ref.parent_post.user)
        }

      match?(%User{}, ref.parent_author) ->
        %{post_id: nil, url: nil, author: author_ref(ref.parent_author)}

      true ->
        %{post_id: nil, url: nil, author: nil}
    end
  end

  defp in_reply_to(_post), do: nil

  defp author_ref(%User{} = user) do
    %{username: user.username, name: VutuvWeb.UserHelpers.full_name(user)}
  end

  defp image(%PostImage{} = image) do
    %{
      id: image.id,
      alt: image.alt,
      width: image.width,
      height: image.height,
      position: image.position,
      urls: PostImage.urls(image)
    }
  end

  defp audience(post, viewer) do
    cond do
      match?(%{id: id} when id == post.user_id, viewer) ->
        %{default: "allow", deny: Enum.map(post.denials, &denial/1)}

      Posts.restricted?(post) ->
        %{restricted: true}

      true ->
        %{restricted: false}
    end
  end

  defp denial(%{wildcard: wildcard}) when not is_nil(wildcard),
    do: %{type: "wildcard", value: wildcard}

  defp denial(%{denied_user_id: user_id} = denial),
    do: %{type: "user", id: user_id, username: denial.denied_user.username}
end
