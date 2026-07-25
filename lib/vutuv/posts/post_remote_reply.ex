defmodule Vutuv.Posts.PostRemoteReply do
  @moduledoc """
  One vutuv post that answers a reply written on another network (issue #1070).

  The sidecar to `Vutuv.Posts.PostReply`, not a replacement for it: such an
  answer is still an ordinary reply to the vutuv post underneath, so local
  threading, the reply notification, the public reply count and the edit window
  all keep working untouched. This row records the *other* thing it answers, and
  it is what makes the outgoing `Create(Note)` carry an `inReplyTo` pointing into
  the other network plus a `Mention` of the person being answered.

  **Why it holds its own copy of the target.** A stored remote reply is a cache:
  it is collected six months out (`Vutuv.Fediverse.NoteSweeper`), and a takedown
  or an upstream delete can remove it long before that. The member's own answer
  lives on, and editing or deleting it has to keep reaching the person who was
  answered. So `note_id` nilifies rather than cascading, and everything delivery
  needs is copied here at creation time:

    * `in_reply_to_uri` — the remote note's own id, what `inReplyTo` names.
    * `actor_uri` — who was answered. The `Mention` tag is built from **this**,
      never from parsing the member's typed text, so a member cannot make vutuv
      notify an actor nobody verified.
    * `inbox_uri` — where the answer is delivered, copied from the note (which
      captured it from the actor document the inbox had already verified). Only
      ever an inbox on the actor's own host (`Vutuv.Fediverse.own_inbox/1`).
      Nullable: a note stored before issue #1070 carries none, and then only the
      member's own followers receive the answer.
    * `handle` — the `@user@host` the answer's "Replying to" line shows and the
      outgoing `Mention` names. Cosmetic, remote-supplied, so capped.
  """

  use VutuvWeb, :model

  # Remote URIs are unbounded in theory; cap them in bytes like
  # `Vutuv.Fediverse.Note` does, so a hostile value fails the changeset rather
  # than the insert.
  @max_uri_bytes 2_048

  schema "post_remote_replies" do
    belongs_to(:post, Vutuv.Posts.Post)
    belongs_to(:note, Vutuv.Fediverse.Note)

    field(:in_reply_to_uri, :string)
    field(:actor_uri, :string)
    field(:inbox_uri, :string)
    field(:handle, :string)

    timestamps()
  end

  def changeset(%__MODULE__{} = remote_reply, attrs) do
    remote_reply
    |> cast(attrs, [:note_id, :in_reply_to_uri, :actor_uri, :inbox_uri, :handle])
    |> validate_required([:in_reply_to_uri, :actor_uri])
    |> validate_length(:in_reply_to_uri, max: @max_uri_bytes, count: :bytes)
    |> validate_length(:actor_uri, max: @max_uri_bytes, count: :bytes)
    |> validate_length(:inbox_uri, max: @max_uri_bytes, count: :bytes)
    |> validate_length(:handle, max: 255)
    |> unique_constraint(:post_id)
  end
end
