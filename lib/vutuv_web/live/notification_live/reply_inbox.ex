defmodule VutuvWeb.NotificationLive.ReplyInbox do
  @moduledoc """
  The two things a reply inbox row on /notifications loads on demand, never
  for the whole page: the **preview** a pointer shows on hover (the whole
  post, its pictures included) and the **context** its "Show context" button
  folds open (the conversation around the reply, the member's own answers
  in it).

  Both are one reply's worth of work, done when somebody asks for that reply,
  for the reason the page's formatted quote waits for its unfold: fifty rows
  of full Markdown and thread windows would be paid for on every visit and
  looked at for one or two.

  Everything goes through the visibility-scoped lookups
  (`Vutuv.Posts.visible_posts_by_ids/2`, `Vutuv.Posts.thread_window/3`), so a
  post the member may not see is neither previewed nor listed as context.
  """

  alias Vutuv.Activity.ReplyStatus
  alias Vutuv.MarkdownContent
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostImage
  alias VutuvWeb.Markdown
  alias VutuvWeb.PostTeaser
  alias VutuvWeb.UserHelpers

  # How many pictures the preview strip carries before the rest become a count.
  @preview_images 4

  # The context window: the two posts above the reply and the first four of
  # its own subtree (the member's answers are in there), or the whole
  # conversation while it stays at eight posts or fewer.
  @context_opts [ancestors: 2, replies: 4, all_limit: 8]

  # A context line is a teaser, not the post: two lines' worth of characters.
  @context_chars 200

  @doc """
  The hover preview for `item`: `%{html: rendered_body, images: [image], more_images: n}`
  for a reply written here, `%{text: plain_text}` for one from another
  network (plain text on purpose: a stranger's words never go through the
  Markdown renderer, see `VutuvWeb.NotificationLive.Index`'s remote quote), or
  nil when there is nothing the member may see.
  """
  def preview(%{kind: "fediverse_reply"} = item, _viewer) do
    case item[:note_text] do
      text when is_binary(text) and text != "" -> %{text: text}
      _ -> nil
    end
  end

  def preview(item, viewer) do
    with id when is_binary(id) <- ReplyStatus.subject(item, :post),
         %Post{} = post <- Map.get(Posts.visible_posts_by_ids(viewer, [id]), id) do
      images = Map.get(Posts.released_images_by_ids([id]), id, [])
      # The pictures ride their own strip below, so the body drops them.
      body = MarkdownContent.strip_images(post.body || "")

      %{
        html: Markdown.render_post(body, []),
        images: Enum.take(images, @preview_images),
        more_images: max(length(images) - @preview_images, 0)
      }
    else
      _ -> nil
    end
  end

  @doc "The thumbnail URL of a preview picture."
  def image_url(%PostImage{} = image), do: PostImage.url(image, "thumb")

  @doc """
  The conversation around `item`, oldest first, as
  `%{entries: [entry], more?: boolean}`, or nil when the member may not see
  the post. An entry is `%{id, name, at, text, path, current?, mine?}`:
  `current?` marks the reply the row is about, `mine?` the member's own
  posts (their post that was answered, and their answers). `more?` says the
  conversation holds posts the window left out.
  """
  def context(%{kind: "fediverse_reply"} = item, viewer) do
    mine =
      case Map.get(Posts.visible_posts_by_ids(viewer, [item[:post_id]]), item[:post_id]) do
        %Post{} = post -> [post_entry(post, viewer, nil)]
        nil -> []
      end

    note = %{
      id: item[:note_id],
      name: item[:actor_name],
      at: item[:at],
      text: PostTeaser.opening_lines(%Vutuv.Fediverse.Note{content_text: item[:note_text]}),
      path: nil,
      current?: true,
      mine?: false
    }

    answer = if item[:answer], do: [post_entry(item.answer, viewer, nil)], else: []

    %{entries: mine ++ [note] ++ answer, more?: false}
  end

  def context(item, viewer) do
    with id when is_binary(id) <- ReplyStatus.subject(item, :post),
         %Post{} = post <- Map.get(Posts.visible_posts_by_ids(viewer, [id]), id) do
      {posts, more?} = window_posts(Posts.thread_window(post, viewer, @context_opts))
      %{entries: Enum.map(posts, &post_entry(&1, viewer, id)), more?: more?}
    else
      _ -> nil
    end
  end

  defp window_posts(%{mode: :all, posts: posts}), do: {posts, false}

  defp window_posts(%{mode: :window} = window) do
    posts = List.wrap(window.root) ++ window.chain ++ window.subtree
    {posts, window.gap + window.more + window.rest > 0}
  end

  defp post_entry(%Post{} = post, viewer, current_id) do
    %{
      id: post.id,
      name: UserHelpers.author_name(post),
      at: post.inserted_at,
      text: PostTeaser.opening_lines(post, length: @context_chars),
      path: Posts.path(post),
      current?: post.id == current_id,
      mine?: post.user_id == viewer.id
    }
  end
end
