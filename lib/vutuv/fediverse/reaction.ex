defmodule Vutuv.Fediverse.Reaction do
  @moduledoc """
  One remote reaction to a member's post (issue #1068): somebody on another
  network favourited (`like`) or re-shared (`announce`) it.

  **An account address and what they did — nothing more.** No display name, no
  avatar, no text. `actor_uri` earns its place three times over: each remote
  person counts once, an upstream `Undo` finds its row, and the post says who
  answered instead of only that somebody did. `handle` is the same address in
  the notation those networks write it in (`@handle@host`), captured from the
  actor document the inbox fetches anyway to verify the signature.

  That minimalism is the point: vutuv can never obtain consent from a stranger
  on another server, so what makes this lawful is storing almost nothing about
  them and deleting it the moment they, the post or the account go.

  The row's lifetime is the post's lifetime (the FK cascades), exactly like a
  vutuv like. There is no separate expiry.
  """

  use VutuvWeb, :model

  import Vutuv.ChangesetHelpers, only: [scrub_nul: 1]

  alias Vutuv.Fediverse.Handle

  @kinds ~w(like announce)

  # A remote URI is unbounded in theory. Cap it in **bytes**, because the row is
  # part of a btree unique index whose key has a hard size limit — a hostile
  # multi-kilobyte actor id must fail the changeset, never the index insert
  # (which would be a 500 out of the inbox).
  @max_uri_bytes 2_048

  @doc "The reaction kinds vutuv counts."
  def kinds, do: @kinds

  schema "fediverse_reactions" do
    field(:actor_uri, :string)
    field(:handle, :string)
    field(:kind, :string)
    field(:received_at, :utc_datetime)

    belongs_to(:post, Vutuv.Posts.Post)
  end

  @doc """
  How the post names this person: `@handle@host`. Falls back to the actor URI's
  last path segment (rows stored before the handle was kept), then to the bare
  host. Shared with the reply cards and the follower list.
  """
  def display_handle(%__MODULE__{handle: handle, actor_uri: actor_uri}),
    do: Handle.display(handle, actor_uri)

  def changeset(%__MODULE__{} = reaction, attrs) do
    reaction
    |> cast(attrs, [:actor_uri, :handle, :kind, :received_at])
    # Remote strings, and a NUL in one raises on insert (issue #1767). This row
    # is written with `insert_all` from the applied changeset, so the scrub has
    # to sit here or nothing sees it.
    |> scrub_nul()
    |> validate_required([:actor_uri, :kind, :received_at])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:actor_uri, max: @max_uri_bytes, count: :bytes)
    # Remote-supplied and cosmetic: keep a column's worth, never let it 22001.
    |> validate_length(:handle, max: 255)
    |> unique_constraint([:post_id, :actor_uri, :kind])
  end
end
