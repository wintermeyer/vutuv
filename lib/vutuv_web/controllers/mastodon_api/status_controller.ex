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

  # The empty conversation, in Mastodon's own shape — the honest answer
  # wherever there is nothing local to show.
  @empty_context %{ancestors: [], descendants: []}

  # How far up a cached self-thread `/context` follows. A client draws a handful
  # of ancestors above the status somebody opened, and each step is a query.
  @max_remote_ancestors 20

  @doc """
  One status by the id a client was given.

  **A reshare's id resolves to what it passed on.** Reshares are statuses in
  their own right here (`Presenter.reshared/2`), so a client hands back
  `boost-<uuid>` or `repost-<uuid>` — ids that named a reshare row, reached
  `Posts.get_post/1`, missed, and 404ed. Resolving them to the object underneath
  is what Mastodon does with a reblog id too: acting on a reshare is acting on
  the post.
  """
  def show(conn, %{"id" => id}) do
    with_visible_status(conn, id, fn object ->
      json(conn, Presenter.one_status(object, viewer(conn)))
    end)
  end

  # The one spelling of "resolve the id, gate it, or 404" — every read and
  # every action goes through it. Answering 200 to any id that merely resolves
  # tells whoever asks that the object exists, which is the one thing a
  # followers-only cached post must not confirm, so no caller may skip the gate.
  defp with_visible_status(conn, id, fun) do
    case resolve_status(id) do
      nil ->
        not_found(conn)

      object ->
        if status_visible?(conn, object), do: fun.(object), else: not_found(conn)
    end
  end

  # Every id shape the client API mints, in one place. Order matters: the longer
  # `remote-` prefixes have to be read before the bare one, or a cached reply
  # would be looked up as a cached post.
  defp resolve_status("remote-note-" <> id), do: Fediverse.get_note(id)
  defp resolve_status("remote-reply-repost-" <> id), do: Fediverse.get_reposted_note(id)
  defp resolve_status("remote-repost-" <> id), do: Fediverse.get_reposted_remote_post(id)
  defp resolve_status("remote_repost-" <> id), do: Fediverse.get_reposted_remote_post(id)
  defp resolve_status("remote-" <> id), do: Fediverse.get_remote_post(id)
  defp resolve_status("boost-" <> id), do: Fediverse.get_boosted_object(id)
  defp resolve_status("repost-" <> id), do: Posts.get_reposted_post(id)
  defp resolve_status(id), do: Posts.get_post(id)

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
        {:ok, updated} ->
          json(conn, Presenter.one_status(updated, viewer(conn)))

        {:error, :invalid_images} ->
          validation_error(conn, "Unknown or foreign media ids.")

        {:error, :too_many_images} ->
          validation_error(conn, "Too many images.")

        # vutuv closes editing where Mastodon leaves it open, so the two reasons
        # for that are spelled out rather than collapsing into "the status is
        # invalid" — the member is not being told about a broken request but
        # about a rule, and one they can neither see nor work around from a
        # client. See `Posts.update_post/2`.
        {:error, :edit_engaged} ->
          validation_error(
            conn,
            "This post can no longer be edited: somebody has liked, boosted or replied to it, " <>
              "and an edit would rewrite what they put their name to. You can still delete it."
          )

        {:error, :edit_window_closed} ->
          validation_error(
            conn,
            "This post can no longer be edited: the #{Posts.edit_window_minutes()}-minute " <>
              "edit window has closed. You can still delete it."
          )

        {:error, :visibility_locked} ->
          validation_error(
            conn,
            "This post's audience can no longer be narrowed: somebody has boosted or replied to it."
          )

        {:error, reason} ->
          validation_error(conn, changeset_error(reason))
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
  rather than with a second set of queries.

  **A conversation that crossed a network border stays one conversation**
  (issue #1640). Where a post here answers something we hold a cache of, that
  cached reply or cached post is a node in the same walk — and a followed
  account's self-reply gets the author's own thread above it. Only what this
  installation can serve under an id of its own takes part; nothing is invented
  from a bare URI, which would name a status no client here could fetch.
  """
  def context(conn, %{"id" => id}) do
    with_visible_status(conn, id, fn object ->
      json(conn, context_payload(conn, object))
    end)
  end

  defp context_payload(conn, %Post{} = post), do: thread_context(conn, post)

  # A cached reply is by definition an answer to a local post (`note.post_id`),
  # so the reader who opens it gets the conversation above: the parent post's
  # own chain plus the parent, oldest first. Gated like every other read here —
  # a parent the viewer may not see must not ride in on its reply's id, and
  # `list_thread/2` unions the focus post back in unconditionally, so the check
  # cannot be left to the query. The bare row is enough for that gate
  # (`visible_to?/2` looks up whatever is not preloaded), and the copy that gets
  # rendered comes out of `list_thread/2` preloaded. Descendants stay empty: a
  # local answer to this reply lives in the parent's thread and is read there.
  defp context_payload(conn, %Note{} = note) do
    with %Post{} = parent <- Repo.get(Post, note.post_id),
         true <- status_visible?(conn, parent) do
      # Seeded at the parent **inclusive**: the reply is the focus, so the post
      # it hangs under is its youngest ancestor rather than the start of a walk.
      ancestors_above(conn, parent, parent.id)
    else
      _gone_or_closed -> @empty_context
    end
  end

  # A cached post is a self-reply whenever its author carried their own thread
  # on, and `own_thread?/2` is what makes following that safe: a stored reply's
  # parent is always another cached post by the **same** account, so the chain
  # above is one we hold and can serve. Descendants stay empty — an answer
  # written here to a cached post lives in its own thread and is read there.
  defp context_payload(conn, %RemotePost{} = post) do
    %{
      ancestors: Presenter.statuses(remote_ancestors(conn, post), viewer(conn)),
      descendants: []
    }
  end

  # The conversation above `seed`, with no answers below it — `root`'s thread is
  # what gets loaded, `seed` is where the walk up starts.
  defp ancestors_above(conn, %Post{} = root, seed) do
    viewer = viewer(conn)
    %{posts: posts} = Posts.list_thread(root, viewer)
    {parents, by_id} = thread_graph(conn, posts)
    chain = for id <- ancestor_chain(parents, seed, []), p = by_id[id], do: p

    %{ancestors: Presenter.statuses(chain, viewer), descendants: []}
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

  # Answering goes through the same resolution as everything else, so a client
  # that replies while looking at a reshare answers the post rather than being
  # told the status does not exist.
  defp create_reply(user, id, attrs) do
    case resolve_status(id) do
      %Note{} = note -> Posts.create_remote_reply(user, note, attrs)
      %RemotePost{} = post -> Posts.create_remote_post_reply(user, post, attrs)
      %Post{} = post -> Posts.create_reply(user, post, attrs)
      nil -> {:error, :not_found}
    end
  end

  defp status_action(conn, id, action) do
    with_visible_status(conn, id, &perform_status_action(conn, &1, action))
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

  # **A refusal a member can act on has to say what to do**, and every reason a
  # cached post can refuse for used to collapse into one sentence that names
  # nothing: "The status action could not be completed." A member whose account
  # simply does not federate yet was told exactly what a member hitting their
  # hourly budget was told, and both read as a broken button — which is how
  # "posts from the fediverse cannot be favourited" was reported. These are the
  # reasons `Vutuv.Fediverse`'s outbound gates answer with; anything else keeps
  # the catch-all below.
  defp action_error(:not_federating) do
    "Turn Fediverse publishing on for your account first: a like, boost or reply " <>
      "leaves this site signed with your own key, and an account that does not " <>
      "federate has none. You can switch it on under Settings, Privacy, Fediverse."
  end

  defp action_error(:fediverse_disabled),
    do: "This installation does not talk to the Fediverse."

  defp action_error(:moved),
    do: "Your account is redirected to another server, so nothing leaves this one any more."

  defp action_error(:instance_blocked),
    do: "This installation does not exchange anything with that server."

  defp action_error(:not_visible),
    do: "This status is not yours to read, so it is not yours to act on."

  defp action_error(:post_not_public),
    do: "The author narrowed this status, so it cannot be answered or passed on."

  defp action_error(reason) when reason in [:like_capped, :boost_capped, :reply_capped],
    do:
      "You have used this hour's budget for actions that leave for other servers. Try again later."

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
        Fediverse.remote_follow_for(organization, post.remote_account)
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
    viewer = viewer(conn)
    %{posts: posts} = Posts.list_thread(post, viewer)

    {parents, by_id} = thread_graph(conn, posts)
    ancestors = for id <- ancestor_chain(parents, parents[post.id], []), p = by_id[id], do: p
    descendants = Enum.filter(posts, &below?(parents, &1.id, post.id))

    # **One render for both halves.** A thread is mostly the same handful of
    # people, and every `Presenter.statuses/2` call reads their counts
    # (`Vutuv.MastodonApi.AccountCounts`) — rendering ancestors and descendants
    # separately paid for that twice per request, on the call a client makes the
    # moment somebody opens a status.
    rendered = Presenter.statuses(ancestors ++ descendants, viewer)
    {rendered_ancestors, rendered_descendants} = Enum.split(rendered, length(ancestors))

    %{ancestors: rendered_ancestors, descendants: rendered_descendants}
  end

  # Oldest first, which is reading order for a chain of answers.
  defp ancestor_chain(_parents, nil, acc), do: acc

  defp ancestor_chain(parents, id, acc) do
    if id in acc, do: acc, else: ancestor_chain(parents, parents[id], [id | acc])
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

  # The conversation as a graph in the ids a client speaks: what each node
  # answers (`parents`) and the record behind each id (`by_id`). Both halves in
  # one place, so the walk up and the walk down never have to ask where a status
  # came from.
  defp thread_graph(conn, posts) do
    answered = visible_answered(conn, posts)

    # `uniq_by` because two members can answer the same cached object, and each
    # borrowed chain is walked a query at a time.
    borrowed =
      answered
      |> Map.values()
      |> Enum.uniq_by(&Presenter.status_id/1)
      |> Enum.flat_map(&borrowed_chain(conn, &1))

    parents =
      posts
      |> Map.new(&{&1.id, parent_id(&1, answered)})
      |> Map.merge(
        Map.new(borrowed, fn {node, parent} -> {Presenter.status_id(node), parent} end)
      )

    by_id =
      posts
      |> Map.new(&{&1.id, &1})
      |> Map.merge(Map.new(borrowed, fn {node, _parent} -> {Presenter.status_id(node), node} end))

    {parents, by_id}
  end

  # What these posts answer on other networks, minus whatever this reader may
  # not see: an account can narrow a single post to its followers, so holding
  # the cache is not the same as being allowed to read it, and a closed post
  # must not ride into the conversation on a local answer's id.
  defp visible_answered(conn, posts) do
    posts
    |> Enum.map(& &1.id)
    |> Fediverse.answered_objects()
    |> Map.filter(fn {_post_id, object} -> status_visible?(conn, object) end)
  end

  # One borrowed node per entry, as `{record, id it answers}`.
  #
  # A cached reply hangs off a local post, which is the node below it in this
  # same thread. A cached post brings its author's own chain along, so the
  # conversation reads the same whether the client opened the answer written
  # here or the cached post it answers.
  defp borrowed_chain(_conn, %Note{} = note), do: [{note, note.post_id}]

  defp borrowed_chain(conn, %RemotePost{} = post) do
    chain = remote_ancestors(conn, post) ++ [post]

    # Each node answers the one before it; the oldest answers nothing we hold.
    Enum.zip(chain, [nil | Enum.map(chain, &Presenter.status_id/1)])
  end

  # The cached posts above `post` in its author's own thread, oldest first.
  # Gated one row at a time, since an account can narrow a single post to its
  # followers. Two brakes, because a cache of somebody else's data is not ours
  # to trust: a `seen` set, so a pair of posts naming each other cannot pad the
  # chain with a loop, and a hard cap, because a client draws a handful of
  # ancestors and every step here is a query.
  defp remote_ancestors(conn, post, acc \\ [], seen \\ MapSet.new())

  defp remote_ancestors(_conn, _post, acc, _seen) when length(acc) >= @max_remote_ancestors,
    do: acc

  defp remote_ancestors(conn, post, acc, seen) do
    seen = MapSet.put(seen, post.id)

    with %RemotePost{} = parent <- Fediverse.remote_parent_post(post),
         false <- MapSet.member?(seen, parent.id),
         true <- status_visible?(conn, parent) do
      remote_ancestors(conn, parent, [parent | acc], seen)
    else
      _end_of_chain -> acc
    end
  end

  # What a post answers — the cached reply or cached post it addresses on
  # another network where it has one, otherwise the local post above it. The
  # remote side wins because it is the *closer* parent: an answer to a cached
  # reply is filed as an ordinary local reply to the post that reply hangs under
  # (issue #1070), so naming the local one hangs it a level too high, which is
  # exactly what a client then draws (issue #1641).
  defp parent_id(%Post{} = post, answered) do
    case answered[post.id] do
      nil -> local_parent_id(post)
      object -> Presenter.status_id(object)
    end
  end

  defp local_parent_id(%Post{} = post) do
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
