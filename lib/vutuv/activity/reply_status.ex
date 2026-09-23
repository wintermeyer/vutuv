defmodule Vutuv.Activity.ReplyStatus do
  @moduledoc """
  What the member already did about each reply in the reply inbox on
  /notifications: whether they answered it (and with what) and whether they
  liked it.

  Read-time state, like the rest of the feed: nothing is stored for it. An
  answer is a post of the member's directly under the reply (`post_replies`,
  or `post_remote_replies` for a reply from another network); a like is their
  row in `post_likes` / `fediverse_note_likes`. Deleting the answer or taking
  the like back therefore undoes the state, with no second place that has to
  remember.

  The "which post would I answer" rule is the one `Vutuv.Activity`'s
  `answered_scope/4` filters the inbox by, so a row the Answered filter keeps
  always shows its answer here, and the other way round.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostLike
  alias Vutuv.Posts.PostRemoteReply
  alias Vutuv.Posts.PostReply
  alias Vutuv.Repo

  @doc """
  Put `:answer` (the member's newest post directly under the entry's subject,
  or nil) and `:liked?` on every entry. At most four queries for the whole
  batch plus one preloading the answers' author, none for a batch without
  replies. Entries of other kinds pass through with `answer: nil, liked?:
  false`.
  """
  def put(%User{} = _user, []), do: []

  def put(%User{} = user, entries) do
    post_ids = subjects(entries, :post)
    note_ids = subjects(entries, :note)

    answers =
      Map.merge(
        answers(PostReply, :parent_post_id, user.id, post_ids),
        answers(PostRemoteReply, :note_id, user.id, note_ids)
      )

    liked = MapSet.union(liked_posts(user.id, post_ids), liked_notes(user, note_ids))

    Enum.map(entries, fn entry ->
      key = subject(entry, :post) || subject(entry, :note)

      entry
      |> Map.put(:answer, key && answers[key])
      |> Map.put(:liked?, key != nil and MapSet.member?(liked, key))
    end)
  end

  @doc """
  The post the member would answer for `entry` (`:post`), or the note
  (`:note`): the reply itself, the thread answer, the post that named them, or
  the reply from another network. Nil for every other kind.
  """
  def subject(%{kind: kind} = entry, :post) when kind in ~w(reply thread),
    do: entry[:reply_post_id]

  def subject(%{kind: "mention"} = entry, :post), do: entry[:post_id]
  def subject(%{kind: "fediverse_reply"} = entry, :note), do: entry[:note_id]
  def subject(_entry, _side), do: nil

  defp subjects(entries, side),
    do: entries |> Enum.map(&subject(&1, side)) |> Enum.reject(&is_nil/1)

  # The member's newest post under each subject, `%{subject_id => %Post{}}`,
  # its author preloaded because the row links it (`Vutuv.Posts.path/1`).
  # `schema` is the table that points a post at what it answers, `key` its
  # column naming the subject.
  defp answers(_schema, _key, _user_id, []), do: %{}

  defp answers(schema, key, user_id, ids) do
    from(r in schema,
      join: p in Post,
      on: p.id == r.post_id,
      where: p.user_id == ^user_id and field(r, ^key) in ^ids,
      order_by: [desc: p.inserted_at, desc: p.id],
      preload: [post: {p, :user}],
      select: {field(r, ^key), r}
    )
    |> Repo.all()
    # Newest first, so the first one per subject wins.
    |> Enum.reduce(%{}, fn {id, row}, acc -> Map.put_new(acc, id, row.post) end)
  end

  defp liked_posts(_user_id, []), do: MapSet.new()

  defp liked_posts(user_id, ids) do
    from(l in PostLike, where: l.user_id == ^user_id and l.post_id in ^ids, select: l.post_id)
    |> Repo.all()
    |> MapSet.new()
  end

  defp liked_notes(_user, []), do: MapSet.new()
  defp liked_notes(user, ids), do: Fediverse.liked_note_ids(user, ids)
end
