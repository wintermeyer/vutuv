defmodule Vutuv.Fediverse.Reaction do
  @moduledoc """
  One remote reaction to a member's post (issue #1068): somebody on another
  network favourited (`like`) or re-shared (`announce`) it.

  **Counts only.** No display name, no avatar, no text — the actor URI is stored
  for exactly two reasons: so each remote person counts once, and so an upstream
  `Undo` can find its row. That minimalism is the point: vutuv can never obtain
  consent from a stranger on another server, so what makes this lawful is
  storing almost nothing about them and deleting it the moment they, the post or
  the account go.

  The row's lifetime is the post's lifetime (the FK cascades), exactly like a
  vutuv like. There is no separate expiry.
  """

  use VutuvWeb, :model

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
    field(:kind, :string)
    field(:received_at, :utc_datetime)

    belongs_to(:post, Vutuv.Posts.Post)
  end

  def changeset(%__MODULE__{} = reaction, attrs) do
    reaction
    |> cast(attrs, [:actor_uri, :kind, :received_at])
    |> validate_required([:actor_uri, :kind, :received_at])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:actor_uri, max: @max_uri_bytes, count: :bytes)
    |> unique_constraint([:post_id, :actor_uri, :kind])
  end
end
