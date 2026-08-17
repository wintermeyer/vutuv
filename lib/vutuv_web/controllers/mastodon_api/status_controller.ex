defmodule VutuvWeb.MastodonApi.StatusController do
  @moduledoc "Reads and writes the core Mastodon Status resource."

  use VutuvWeb, :controller

  alias Ecto.Changeset
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.MastodonApi.Presenter
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Repo

  def show(conn, %{"id" => "remote-note-" <> id}) do
    case Fediverse.get_note(id) do
      nil ->
        not_found(conn)

      note ->
        if note_visible?(conn, note),
          do: json(conn, Presenter.status(note)),
          else: not_found(conn)
    end
  end

  def show(conn, %{"id" => "remote-" <> id}) do
    case Fediverse.get_remote_post(id) do
      nil ->
        not_found(conn)

      post ->
        if remote_post_visible?(conn, post),
          do: json(conn, Presenter.status(post)),
          else: not_found(conn)
    end
  end

  def show(conn, %{"id" => id}) do
    case Posts.get_post(id) do
      %Post{} = post ->
        subject = conn.assigns.current_organization || conn.assigns.current_user

        if Posts.visible_to?(post, subject),
          do: json(conn, Presenter.one_status(post, subject)),
          else: not_found(conn)

      nil ->
        not_found(conn)
    end
  end

  def create(conn, %{"status" => body} = params) when is_binary(body) do
    with :ok <- validate_visibility(params["visibility"]),
         {:ok, image_ids} <- resolve_media(conn, params["media_ids"]),
         {:ok, post} <- create_post(conn, params, %{body: body, image_ids: image_ids}) do
      conn |> put_status(200) |> json(Presenter.one_status(post, viewer(conn)))
    else
      {:error, :unsupported_visibility} ->
        validation_error(conn, "Only public statuses are supported.")

      {:error, :unknown_media} ->
        validation_error(conn, "Upload the media first; unknown or already attached ids.")

      {:error, :too_many_images} ->
        validation_error(conn, "At most #{Posts.max_images_per_post()} images per status.")

      {:error, %Changeset{} = changeset} ->
        validation_error(conn, changeset_error(changeset))

      {:error, _reason} ->
        validation_error(conn, "The status could not be published.")
    end
  end

  def create(conn, _params), do: validation_error(conn, "Status text is required.")

  def update(conn, %{"id" => id, "status" => body}) when is_binary(body) do
    with :ok <- validate_visibility(conn.params["visibility"]),
         %Post{} = post <- own_post(conn, id) do
      post = Repo.preload(post, :images)

      # An edit that names no media keeps what the post carries; one that does
      # is the new set, so a client can add a picture or drop one. `Posts`
      # re-checks every id against its uploader and against this post, so an id
      # from somebody else's upload cannot ride in here.
      image_ids = edited_image_ids(conn.params["media_ids"], post)

      # Merged **under** the edit: `update_post/2` replaces the audience and the
      # tags with whatever the attrs carry, and a Mastodon client speaks neither.
      # Naming only body and images therefore did not leave them alone, it
      # cleared them — a post its author had closed to somebody came back public
      # and was federated that way, silently. See `unchanged_audience_attrs/1`.
      attrs = Map.merge(Posts.unchanged_audience_attrs(post), %{body: body, image_ids: image_ids})

      case Posts.update_post(post, attrs) do
        {:ok, updated} -> json(conn, Presenter.one_status(updated, viewer(conn)))
        {:error, :invalid_images} -> validation_error(conn, "Unknown or foreign media ids.")
        {:error, :too_many_images} -> validation_error(conn, "Too many images.")
        {:error, reason} -> validation_error(conn, changeset_error(reason))
      end
    else
      {:error, :unsupported_visibility} ->
        validation_error(conn, "Only public statuses are supported.")

      nil ->
        not_found(conn)
    end
  end

  def update(conn, _params), do: validation_error(conn, "Status text is required.")

  # Mastodon answers a delete with the status it just removed, so it is rendered
  # before the row is gone. A failed delete used to raise on the `{:ok, _}`
  # match, which reaches a client as a 500 with an HTML body it cannot parse —
  # for the one call where it most needs to know whether the post is still
  # there. It gets JSON either way now.
  def delete(conn, %{"id" => id}) do
    case own_post(conn, id) do
      %Post{} = post ->
        rendered = Presenter.one_status(post, viewer(conn))

        case Posts.delete_post(post) do
          {:ok, _deleted} -> json(conn, rendered)
          {:error, reason} -> validation_error(conn, changeset_error(reason))
        end

      nil ->
        not_found(conn)
    end
  end

  @doc """
  The conversation around a status, split the way Mastodon splits it:
  `ancestors` are the chain of posts this one answers, oldest first, and
  `descendants` is everything below it in reading order.

  `Vutuv.Posts.list_thread/3` already loads the visibility-scoped conversation
  the permalink renders, so the split is done on the parent links it preloads
  rather than with a second set of queries. Only vutuv posts take part: a reply
  written on another network is cached without a place in the local reply tree,
  and inventing one would put words in the wrong conversation.
  """
  def context(conn, %{"id" => id}) do
    case Posts.get_post(id) do
      %Post{} = post ->
        if status_visible?(conn, post),
          do: json(conn, thread_context(conn, post)),
          else: not_found(conn)

      nil ->
        not_found(conn)
    end
  end

  @doc """
  The status as its author typed it — the Markdown source, not the rendered
  HTML. Clients fetch this before opening their editor; without it they would
  put rendered markup into the edit box and save it back as the body.
  """
  def source(conn, %{"id" => id}) do
    case own_post(conn, id) do
      %Post{} = post ->
        json(conn, %{id: post.id, text: post.body || "", spoiler_text: ""})

      nil ->
        not_found(conn)
    end
  end

  def favourite(conn, %{"id" => id}), do: status_action(conn, id, :favourite)
  def unfavourite(conn, %{"id" => id}), do: status_action(conn, id, :unfavourite)
  def reblog(conn, %{"id" => id}), do: status_action(conn, id, :reblog)
  def unreblog(conn, %{"id" => id}), do: status_action(conn, id, :unreblog)
  def bookmark(conn, %{"id" => id}), do: status_action(conn, id, :bookmark)
  def unbookmark(conn, %{"id" => id}), do: status_action(conn, id, :unbookmark)

  defp create_post(
         %{assigns: %{current_organization: nil}} = conn,
         %{"in_reply_to_id" => id},
         attrs
       )
       when is_binary(id),
       do: create_reply(conn.assigns.current_user, id, attrs)

  defp create_post(%{assigns: %{current_organization: nil, current_user: user}}, _params, attrs),
    do: Posts.create_post(user, attrs)

  defp create_post(
         %{assigns: %{current_organization: organization, current_user: user}},
         params,
         attrs
       ) do
    if is_binary(params["in_reply_to_id"]),
      do: {:error, :unsupported},
      else: Posts.create_organization_post(organization, user, attrs)
  end

  defp create_reply(user, "remote-note-" <> id, attrs) do
    case Fediverse.get_note(id) do
      nil -> {:error, :not_found}
      note -> Posts.create_remote_reply(user, note, attrs)
    end
  end

  defp create_reply(user, "remote-" <> id, attrs) do
    case Fediverse.get_remote_post(id) do
      nil -> {:error, :not_found}
      post -> Posts.create_remote_post_reply(user, post, attrs)
    end
  end

  defp create_reply(user, id, attrs) do
    case Posts.get_post(id) do
      nil -> {:error, :not_found}
      post -> Posts.create_reply(user, post, attrs)
    end
  end

  defp status_action(conn, "remote-note-" <> id, action) do
    case Fediverse.get_note(id) do
      nil -> not_found(conn)
      note -> maybe_perform_status_action(conn, note, action)
    end
  end

  defp status_action(conn, "remote-" <> id, action) do
    case Fediverse.get_remote_post(id) do
      nil -> not_found(conn)
      post -> maybe_perform_status_action(conn, post, action)
    end
  end

  defp status_action(conn, id, action) do
    case Posts.get_post(id) do
      nil -> not_found(conn)
      post -> maybe_perform_status_action(conn, post, action)
    end
  end

  defp maybe_perform_status_action(conn, post, action) do
    if status_visible?(conn, post),
      do: perform_status_action(conn, post, action),
      else: not_found(conn)
  end

  defp perform_status_action(conn, post, action) do
    case apply_status_action(conn, post, action) do
      :ok -> render_status_action(conn, post, action)
      {:ok, _result} -> render_status_action(conn, post, action)
      {:error, reason} -> validation_error(conn, action_error(reason))
    end
  end

  defp apply_status_action(
         %{assigns: %{current_organization: nil, current_user: user}},
         %Post{} = post,
         action
       ),
       do: apply_local_action(user, nil, post, action)

  defp apply_status_action(
         %{assigns: %{current_organization: organization, current_user: user}},
         %Post{} = post,
         action
       ),
       do: apply_local_action(organization, user, post, action)

  defp apply_status_action(
         %{assigns: %{current_organization: nil, current_user: user}},
         %Note{} = note,
         action
       ),
       do: apply_note_action(user, note, action)

  defp apply_status_action(
         %{assigns: %{current_organization: nil, current_user: user}},
         %RemotePost{} = post,
         action
       ),
       do: apply_remote_action(user, post, action)

  defp apply_status_action(_conn, _remote_post, _action), do: {:error, :unsupported}

  defp apply_local_action(actor, nil, post, :favourite), do: Posts.like_post(actor, post)
  defp apply_local_action(actor, nil, post, :unfavourite), do: Posts.unlike_post(actor, post)
  defp apply_local_action(actor, nil, post, :reblog), do: Posts.repost_post(actor, post)
  defp apply_local_action(actor, nil, post, :unreblog), do: Posts.unrepost_post(actor, post)
  defp apply_local_action(actor, nil, post, :bookmark), do: Posts.bookmark_post(actor, post)
  defp apply_local_action(actor, nil, post, :unbookmark), do: Posts.unbookmark_post(actor, post)

  defp apply_local_action(organization, user, post, :favourite),
    do: Posts.like_post(organization, user, post)

  defp apply_local_action(organization, _user, post, :unfavourite),
    do: Posts.unlike_post(organization, post)

  defp apply_local_action(organization, user, post, :reblog),
    do: Posts.repost_post(organization, user, post)

  defp apply_local_action(organization, _user, post, :unreblog),
    do: Posts.unrepost_post(organization, post)

  defp apply_local_action(organization, user, post, :bookmark),
    do: Posts.bookmark_post(organization, user, post)

  defp apply_local_action(organization, _user, post, :unbookmark),
    do: Posts.unbookmark_post(organization, post)

  defp apply_remote_action(user, post, :favourite), do: Fediverse.like_remote_post(user, post)
  defp apply_remote_action(user, post, :unfavourite), do: Fediverse.unlike_remote_post(user, post)
  defp apply_remote_action(user, post, :reblog), do: Fediverse.repost_remote_post(user, post)
  defp apply_remote_action(user, post, :unreblog), do: Fediverse.unrepost_remote_post(user, post)
  defp apply_remote_action(user, post, :bookmark), do: Fediverse.bookmark_remote_post(user, post)

  defp apply_remote_action(user, post, :unbookmark),
    do: Fediverse.unbookmark_remote_post(user, post)

  defp apply_note_action(user, note, :favourite), do: Fediverse.like_note(user, note)
  defp apply_note_action(user, note, :unfavourite), do: Fediverse.unlike_note(user, note)
  defp apply_note_action(user, note, :reblog), do: Fediverse.repost_note(user, note)
  defp apply_note_action(user, note, :unreblog), do: Fediverse.unrepost_note(user, note)
  defp apply_note_action(user, note, :bookmark), do: Fediverse.bookmark_note(user, note)
  defp apply_note_action(user, note, :unbookmark), do: Fediverse.unbookmark_note(user, note)

  defp render_status_action(conn, post, action) do
    field =
      case action do
        value when value in [:favourite, :unfavourite] -> :favourited
        value when value in [:reblog, :unreblog] -> :reblogged
        value when value in [:bookmark, :unbookmark] -> :bookmarked
      end

    enabled? = action in [:favourite, :reblog, :bookmark]
    json(conn, Map.put(Presenter.one_status(post, viewer(conn)), field, enabled?))
  end

  defp action_error(:self), do: "You cannot favourite your own status."
  defp action_error(:restricted), do: "This status cannot be reblogged."
  defp action_error(:unsupported), do: "This identity cannot perform that action."
  defp action_error(:not_found), do: "The referenced status no longer exists."
  defp action_error(_reason), do: "The status action could not be completed."

  defp note_visible?(%{assigns: %{current_organization: nil, current_user: user}}, note),
    do: Fediverse.note_readable?(note, user)

  defp note_visible?(_conn, note), do: Note.public?(note)

  defp remote_post_visible?(%{assigns: %{current_organization: nil, current_user: user}}, post),
    do: Fediverse.remote_post_readable?(post, user)

  defp remote_post_visible?(%{assigns: %{current_organization: organization}}, post) do
    RemotePost.open?(post) or
      match?(
        %{state: "accepted"},
        Fediverse.organization_remote_follow_for(organization, post.remote_account)
      )
  end

  defp status_visible?(conn, %Note{} = note), do: note_visible?(conn, note)
  defp status_visible?(conn, %RemotePost{} = post), do: remote_post_visible?(conn, post)

  defp status_visible?(conn, %Post{} = post) do
    subject = conn.assigns.current_organization || conn.assigns.current_user
    Posts.visible_to?(post, subject)
  end

  defp viewer(conn), do: conn.assigns.current_organization || conn.assigns.current_user

  defp own_post(conn, id) do
    case {conn.assigns.current_organization, conn.assigns.current_user.id, Posts.get_post(id)} do
      {nil, user_id, %Post{organization_id: nil, user_id: user_id} = post} ->
        post

      {%{id: organization_id}, _user_id, %Post{organization_id: organization_id} = post} ->
        post

      _other ->
        nil
    end
  end

  defp thread_context(conn, %Post{} = post) do
    viewer = conn.assigns.current_organization || conn.assigns.current_user
    %{posts: posts} = Posts.list_thread(post, viewer)

    parents = Map.new(posts, &{&1.id, parent_id(&1)})
    ancestors = ancestor_chain(parents, parents[post.id], [])
    descendants = Enum.filter(posts, &below?(parents, &1.id, post.id))

    %{
      ancestors: render_thread(posts, ancestors, viewer),
      descendants: Presenter.statuses(descendants, viewer)
    }
  end

  # Oldest first, which is reading order for a chain of answers.
  defp ancestor_chain(_parents, nil, acc), do: acc

  defp ancestor_chain(parents, id, acc) do
    if id in acc, do: acc, else: ancestor_chain(parents, parents[id], [id | acc])
  end

  defp render_thread(posts, ids, viewer) do
    by_id = Map.new(posts, &{&1.id, &1})
    Presenter.statuses(for(id <- ids, post = by_id[id], do: post), viewer)
  end

  # Walks up rather than down: a post is a descendant when the focus is
  # somewhere on its parent chain. Guarded against a cycle a corrupt reply row
  # could otherwise turn into an endless walk.
  defp below?(parents, id, focus_id, seen \\ MapSet.new())
  defp below?(_parents, nil, _focus_id, _seen), do: false

  defp below?(parents, id, focus_id, seen) do
    cond do
      MapSet.member?(seen, id) -> false
      parents[id] == focus_id -> true
      true -> below?(parents, parents[id], focus_id, MapSet.put(seen, id))
    end
  end

  defp parent_id(%Post{} = post) do
    case Posts.reply_ref_state(post) do
      {:parent, %Post{id: id}} -> id
      _not_a_reply -> nil
    end
  end

  defp validate_visibility(nil), do: :ok
  defp validate_visibility("public"), do: :ok
  defp validate_visibility(_other), do: {:error, :unsupported_visibility}

  # `media_ids[]` are resolved against the **acting member's** own unattached
  # uploads, never the organization's — a page has no uploads of its own, its
  # pictures are the ones the publisher put there. Resolving before the insert
  # turns a stale or foreign id into a 422 the client can explain, rather than
  # the rollback the data layer would raise underneath.
  defp resolve_media(_conn, nil), do: {:ok, []}
  defp resolve_media(_conn, []), do: {:ok, []}

  defp resolve_media(conn, media_ids) when is_list(media_ids) do
    ids = Enum.map(media_ids, &to_string/1)

    case Posts.pending_images(conn.assigns.current_user, ids) do
      images when length(images) == length(ids) -> {:ok, Enum.map(images, & &1.id)}
      _missing_or_foreign -> {:error, :unknown_media}
    end
  end

  defp resolve_media(conn, media_id), do: resolve_media(conn, [media_id])

  defp edited_image_ids(nil, post), do: Enum.map(post.images, & &1.id)
  defp edited_image_ids([], _post), do: []

  defp edited_image_ids(media_ids, _post) when is_list(media_ids),
    do: Enum.map(media_ids, &to_string/1)

  defp edited_image_ids(media_id, post), do: edited_image_ids([media_id], post)

  defp validation_error(conn, message) do
    conn |> put_status(422) |> json(%{error: "Validation failed: " <> message})
  end

  defp changeset_error(%Changeset{} = changeset) do
    changeset
    |> Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
    |> Enum.join(", ")
  end

  defp changeset_error(_other), do: "The status is invalid."
  defp not_found(conn), do: conn |> put_status(404) |> json(%{error: "Record not found"})
end
