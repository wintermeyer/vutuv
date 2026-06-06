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

  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostImage

  @doc "Serializes a preloaded post for `viewer` (a `%User{}` or `nil`)."
  def post(%Post{} = post, viewer) do
    %{
      id: post.id,
      slug: Post.slug(post),
      url: VutuvWeb.Endpoint.url() <> Posts.path(post),
      author: %{
        slug: post.user.active_slug,
        name: VutuvWeb.UserHelpers.full_name(post.user)
      },
      body_markdown: post.body,
      body_html:
        post.body
        |> VutuvWeb.Markdown.render_post(post.images)
        |> Phoenix.HTML.safe_to_string(),
      published_at: post.inserted_at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601(),
      tags: Enum.map(post.tags, & &1.name),
      images: Enum.map(post.images, &image/1),
      audience: audience(post, viewer)
    }
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

  defp denial(%{group_id: group_id} = denial) when not is_nil(group_id),
    do: %{type: "group", id: group_id, name: denial.group.name}

  defp denial(%{denied_user_id: user_id} = denial),
    do: %{type: "user", id: user_id, slug: denial.denied_user.active_slug}
end
