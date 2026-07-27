defmodule Vutuv.Fediverse.RemoteAccount do
  @moduledoc """
  An account on another network that somebody here follows (issue #1160).

  One row per remote actor, however many members follow it. Written when a
  member resolves a handle, re-synced from the actor document whenever that
  server broadcasts an `Update` of itself, and removed with everything hanging
  off it when the operator blocks its server.

  It is the mirror image of `Vutuv.Fediverse.Follower` (who out there follows
  a member here) and deliberately keeps the same fields: the actor URI is the
  identity, the inbox pair is where activities go, the two display strings are
  cosmetic and untrusted. What it adds is the account's own `summary` — the
  self-description — because deciding whether to follow somebody needs more
  than a handle, and the public key, because a followed account's posts arrive
  signed and have to be verifiable without re-fetching the actor every time.

  `host` is denormalized out of `actor_uri` rather than parsed in SQL: it is
  read by the browser's Server column, its filter and the instance purge, and
  a stored value keeps all three reading the same thing.
  """

  use VutuvWeb, :model

  alias Vutuv.Fediverse.Handle

  # Remote URIs are unbounded in theory; cap generously (they are `text`
  # columns) so a hostile payload cannot store megabytes. actor_uri carries a
  # btree unique index, so its cap also has to stay under Postgres' ~2704-byte
  # key limit — 2048 bytes does.
  @max_uri 2_048

  # The display strings are cosmetic and come from a remote actor document, so
  # `Vutuv.Fediverse.fetch_remote_actor/2` already truncates them to this
  # length; the validation is only a backstop.
  @max_display 255

  # A self-description is prose, so it gets a text column and a generous cap
  # rather than a varchar — the same call the post descriptions made.
  @max_summary 10_000

  schema "fediverse_remote_accounts" do
    field(:actor_uri, :string)
    field(:host, :string)
    field(:handle, :string)
    field(:name, :string)
    field(:summary, :string)
    field(:inbox_uri, :string)
    field(:shared_inbox_uri, :string)
    field(:public_key_id, :string)
    field(:public_key_pem, :string)
    field(:refreshed_at, :utc_datetime)

    has_many(:follows, Vutuv.Fediverse.Follow, foreign_key: :remote_account_id)

    timestamps()
  end

  def changeset(%__MODULE__{} = account, attrs) do
    account
    |> cast(attrs, [
      :actor_uri,
      :host,
      :handle,
      :name,
      :summary,
      :inbox_uri,
      :shared_inbox_uri,
      :public_key_id,
      :public_key_pem,
      :refreshed_at
    ])
    |> validate_required([:actor_uri, :host, :inbox_uri])
    |> validate_length(:actor_uri, max: @max_uri, count: :bytes)
    |> validate_length(:inbox_uri, max: @max_uri, count: :bytes)
    |> validate_length(:shared_inbox_uri, max: @max_uri, count: :bytes)
    |> validate_length(:public_key_id, max: @max_uri, count: :bytes)
    |> validate_length(:public_key_pem, max: @max_uri, count: :bytes)
    |> validate_length(:host, max: @max_display)
    |> validate_length(:handle, max: @max_display)
    |> validate_length(:name, max: @max_display)
    |> validate_length(:summary, max: @max_summary)
    |> unique_constraint(:actor_uri)
  end

  @doc "The longest self-description a row may carry."
  def max_summary, do: @max_summary

  @doc """
  The `@user@host` address to show a member, built by the shared
  `Vutuv.Fediverse.Handle` so a followed account, a follower, a reply and a
  reaction never write the same person two different ways on one page.
  """
  def display_handle(%__MODULE__{} = account),
    do: Handle.display(account.handle, account.actor_uri)

  @doc """
  What the account is called on screen: its display name, else the handle, else
  the bare actor URI. Never nil, so a row with no display fields still reads as
  something rather than as a gap.
  """
  def label(%__MODULE__{} = account) do
    presence(account.name) || display_handle(account) || account.actor_uri
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
