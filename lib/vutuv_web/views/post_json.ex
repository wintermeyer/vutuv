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

  @doc "Serializes a preloaded post for `viewer` (a `%User{}` or `nil`)."
  def post(%Post{} = post, viewer) do
    # AI-moderation limbo: the author (and admins) see their own pending
    # images through the API too; everyone else only the released ones.
    images = visible_images(post, viewer)

    %{
      id: post.id,
      url: VutuvWeb.Endpoint.url() <> Posts.path(post),
      author: Vutuv.Identity.ref(Posts.author(post)),
      body_markdown: post.body,
      body_html:
        post.body
        |> VutuvWeb.Markdown.render_post(images)
        |> Phoenix.HTML.safe_to_string(),
      published_at: post.inserted_at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601(),
      tags: Enum.map(post.tags, & &1.name),
      images: Enum.map(images, &image/1),
      reply_count: Posts.reply_count(post.id),
      in_reply_to: in_reply_to(post),
      audience: audience(post, viewer)
    }
  end

  # The reply reference mirrors the card banner's states: a live parent, a
  # deleted post whose author still exists, nothing nameable once the account is
  # gone too, or — for an answer to a post on another network (issue #1165) —
  # the origin URI and the handle it threads under over there. `nil` when the
  # post answers nothing.
  defp in_reply_to(post) do
    case Posts.reply_ref_state(post) do
      {:parent, parent} ->
        %{
          post_id: parent.id,
          url: VutuvWeb.Endpoint.url() <> Posts.path(parent),
          # Whichever author the parent has (issue #1336): a member may answer a
          # post published in a page's name, and `author_ref/1` already speaks
          # both — `parent.user` alone would have shipped `nil` here.
          author: Vutuv.Identity.ref(Posts.author(parent))
        }

      {:author_only, author} ->
        %{post_id: nil, url: nil, author: Vutuv.Identity.ref(author)}

      :gone ->
        %{post_id: nil, url: nil, author: nil}

      nil ->
        remote_in_reply_to(post)
    end
  end

  defp remote_in_reply_to(%{remote_reply_ref: %Vutuv.Posts.PostRemoteReply{} = ref})
       when is_binary(ref.handle),
       do: %{post_id: nil, url: ref.in_reply_to_uri, author: ref.handle, network: "fediverse"}

  defp remote_in_reply_to(_post), do: nil

  # AI-moderation limbo filter: released for everyone, everything for the
  # author and admins (the proxy enforces the same rule on the bytes).
  defp visible_images(%Post{} = post, viewer) do
    case viewer do
      %User{id: id, admin?: admin?} when id == post.user_id or admin? == true ->
        if is_list(post.images), do: post.images, else: []

      _other ->
        Posts.released_images(post)
    end
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
