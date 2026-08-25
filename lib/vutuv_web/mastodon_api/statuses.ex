defmodule VutuvWeb.MastodonApi.Statuses do
  @moduledoc """
  Turning a status id a client sent into the object it names, and deciding
  whether the asker may read it.

  One owner for the whole grammar, because more than one controller asks the
  same question — and issue #1596 is what it costs when they answer it apart.
  `Vutuv.MastodonApi.Presenter` hands a client `repost-<uuid>`, `boost-<uuid>`
  and the `remote-` family as status ids in their own right (issue #1588);
  `VutuvWeb.MastodonApi.StatusController` learned to read them and
  `VutuvWeb.MastodonApi.ListController` kept resolving with
  `Vutuv.Posts.get_post/1` alone. So `/statuses/:id` answered a reshare's id
  while `/statuses/:id/favourited_by` 404ed on the very id the timeline had just
  handed over.

  **A reshare resolves to what it passed on**, which is what Mastodon does with
  a reblog id: reading a reshare is reading the post underneath.

  **A delete does not follow it through, because a delete cannot be taken back.**
  `resolve/1` answers the post, whose author is not the resharer, so a `DELETE`
  routed through it would take the original down on the say-so of an id that
  named somebody else's act. `own_reshare/2` reads the reshare **row** instead —
  a different schema per prefix (`Vutuv.Posts.PostRepost`,
  `Vutuv.Fediverse.PostRepost`, `Vutuv.Fediverse.NoteRepost`) — and hands it over
  only when the row is the caller's own. That check is also what makes the undo
  safe at all: `Vutuv.Posts.unrepost_post/2` takes an actor and a post and drops
  *the caller's* reshare of it, so without it a delete addressed at somebody
  else's row would quietly undo your own.

  `update` and `source` do follow the id through, gated on owning the post that
  comes back: a reshare carries no text of its own, so editing one can only mean
  editing what it passed on, and a reshare of a post that is not yours answers
  404 as it always did.

  The vocabulary is spelled twice here — `resolve/1` reads it for the object,
  `own_reshare/2` for the row — and a third time in
  `VutuvWeb.MastodonApi.Pagination`'s `@id_prefixes`, which strips these words to
  get at the uuid underneath. So `own_reshare/2` **fails closed**: a word it has
  not learned is a reshare it cannot undo, never a post the caller may delete.
  """

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Organizations.Organization
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.UUIDv7

  @doc """
  The object a status id names, or `nil` when it names nothing.

  Order matters: the longer `remote-` prefixes have to be read before the bare
  one, or a cached reply would be looked up as a cached post.
  """
  def resolve("remote-note-" <> id), do: Fediverse.get_note(id)
  def resolve("remote-reply-repost-" <> id), do: Fediverse.get_reposted_note(id)
  def resolve("remote-repost-" <> id), do: Fediverse.get_reposted_remote_post(id)
  def resolve("remote_repost-" <> id), do: Fediverse.get_reposted_remote_post(id)
  def resolve("remote-" <> id), do: Fediverse.get_remote_post(id)
  def resolve("boost-" <> id), do: Fediverse.get_boosted_object(id)
  def resolve("repost-" <> id), do: Posts.get_reposted_post(id)
  def resolve(id), do: Posts.get_post(id)

  @doc """
  The object `id` names **if the asker may read it**, otherwise `nil`.

  The pairing and not just its halves, because the pairing is what drifted:
  resolving and gating were two steps each controller spelled for itself, and
  `ListController` got the first one wrong for every id shape but the bare one. A
  caller that asks this cannot forget either half.
  """
  def visible(conn, id) do
    case resolve(id) do
      nil -> nil
      object -> if visible?(conn, object), do: object
    end
  end

  @doc """
  Whether the identity behind `conn` may read this object.

  Answering 200 to any id that merely resolves tells whoever asks that the
  object exists, which is the one thing a followers-only cached post must not
  confirm — so no caller may skip this.
  """
  def visible?(conn, %Note{} = note), do: note_visible?(conn, note)
  def visible?(conn, %RemotePost{} = post), do: remote_post_visible?(conn, post)
  def visible?(conn, %Post{} = post), do: Posts.visible_to?(post, viewer(conn))

  @doc "The member or page acting on this request."
  def viewer(conn), do: conn.assigns.current_organization || conn.assigns.current_user

  @doc """
  The reshare `id` names, in three answers a write has to tell apart:
  `{:ok, reshare}` when it is the caller's own act, `:not_mine` when the id names
  a reshare that is not, and `:not_a_reshare` when it names no reshare at all.

  The middle answer is the one that has to exist. Collapsing it into "no" would
  send a foreign reshare's id on to whatever handles an ordinary status id — and
  that resolves to the post underneath, which is how a delete aimed at somebody
  else's reshare reaches an original its author never asked about. So
  `:not_a_reshare` is only ever the answer for an id this module can *name*: a
  plain uuid, or one of the two `remote-` prefixes that name an object rather
  than an act. Anything else fails closed.

  A reshare is `%{kind:, object:, at:}` — what was passed on, when, and which of
  the three reshare tables it came from. `kind` is the key
  `Vutuv.MastodonApi.Presenter` reads that object under in a timeline entry
  (`:post`, `:note`, `:remote_post`), so `Presenter.reshared_status/3` can render
  the reshare back without asking a second time what shape it is.

  Ownership rather than visibility, because this answers a write: a reshare of a
  post the caller may read is still not theirs to undo.
  """
  def own_reshare(conn, "remote-reply-repost-" <> id),
    do: own_repost(conn, Fediverse.get_note_repost(id), :note_id, :note, &Fediverse.get_note/1)

  def own_reshare(conn, "remote-repost-" <> id), do: own_remote_post_repost(conn, id)
  def own_reshare(conn, "remote_repost-" <> id), do: own_remote_post_repost(conn, id)

  def own_reshare(conn, "repost-" <> id),
    do: own_repost(conn, Posts.get_post_repost(id), :post_id, :post, &Posts.get_post/1)

  # `fediverse_post_boosts` belongs to an account on another server, so there is
  # no row here a member or a page could own — but the id still names a reshare,
  # and saying so is what keeps it away from the post it carries.
  def own_reshare(_conn, "boost-" <> _uuid), do: :not_mine

  # These two name an object, not an act, so the ordinary lookup is right for
  # them: it answers a cached reply or a cached post, which is nobody's here to
  # delete and therefore 404s on its own.
  def own_reshare(_conn, "remote-note-" <> _uuid), do: :not_a_reshare
  def own_reshare(_conn, "remote-" <> _uuid), do: :not_a_reshare

  def own_reshare(_conn, id),
    do: if(UUIDv7.cast_or_nil(id), do: :not_a_reshare, else: :not_mine)

  defp own_remote_post_repost(conn, id) do
    own_repost(
      conn,
      Fediverse.get_remote_post_repost(id),
      :remote_post_id,
      :remote_post,
      &Fediverse.get_remote_post/1
    )
  end

  # One shape for the three tables a reshare made here can live in: read the row,
  # ask whose act it is, then read what it passed on. `at` is the row's own time,
  # which is when the thing was handed on and therefore the timestamp the reshare
  # wears as a status.
  defp own_repost(conn, row, object_key, kind, load) do
    with %{^object_key => object_id} <- row,
         true <- own_row?(viewer(conn), row),
         object when not is_nil(object) <- load.(object_id) do
      {:ok, %{kind: kind, object: object, at: row.inserted_at}}
    else
      _not_my_reshare -> :not_mine
    end
  end

  # Whose act a reshare row is. A post here can be passed on by a member or by a
  # page (issue #1336), so `post_reposts` carries both columns and exactly one is
  # set; the two fediverse tables only ever carry a member's, and their rows
  # simply miss the `organization_id` key rather than holding a nil.
  defp own_row?(%User{id: id}, %{user_id: id}), do: true
  defp own_row?(%Organization{id: id}, %{organization_id: id}), do: true
  defp own_row?(_viewer, _row), do: false

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
end
