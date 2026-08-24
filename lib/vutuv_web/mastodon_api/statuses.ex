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

  That equivalence holds for **reads only**, and the writes are deliberately not
  routed through here yet. A `DELETE` on `repost-<uuid>` must undo that one
  reshare, and the object this hands back cannot say whose reshare it was:
  `Vutuv.Posts.unrepost_post/2` would find *the caller's* reshare of the same
  post, so a delete addressed at somebody else's row would quietly undo your own.
  Answering that properly needs the reshare **row**, and the row is a different
  schema per prefix (`Vutuv.Posts.PostRepost`, `Vutuv.Fediverse.PostRepost`,
  `Vutuv.Fediverse.NoteRepost`, and `Vutuv.Fediverse.PostBoost`, which belongs to
  a remote account and can never be the caller's). Until that lands, `update`,
  `delete` and `source` keep refusing a reshare id.

  A third home for the same vocabulary is `VutuvWeb.MastodonApi.Pagination`'s
  `@id_prefixes`, which strips these words to get at the uuid underneath.
  """

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Posts
  alias Vutuv.Posts.Post

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
