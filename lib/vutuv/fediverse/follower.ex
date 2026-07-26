defmodule Vutuv.Fediverse.Follower do
  @moduledoc """
  A remote (Fediverse) follower of a member: the remote actor's id URI and
  where to deliver (its inbox, plus the server-wide sharedInbox when the
  remote declares one, so a server with many followers gets each post once).
  Rows are written by the inbox on `Follow` and removed on `Undo`; the remote
  actor's own `Update` re-syncs them and its `Delete` removes them, so a
  renamed remote stops showing under its old handle and a deleted one stops
  counting as a follower.

  Not every account announces its own departure, so `last_checked_at` carries
  the slow re-check that catches the silent ones
  (`Vutuv.Fediverse.FollowerPruner`): when the actor document was last
  re-fetched, `nil` for a row that has never been checked.
  """

  use VutuvWeb, :model

  alias Vutuv.Fediverse.Handle

  # Remote URIs are unbounded in theory; cap generously (they are `text`
  # columns) so a hostile payload cannot store megabytes.
  @max_uri 2_048

  # The display fields are cosmetic and come from a remote actor document, so
  # the caller (`Vutuv.Fediverse.fetch_remote_actor/2`) already truncates them
  # to this length — the validation is only a backstop so a Follow is never
  # rejected over a long name.
  @max_display 255

  schema "fediverse_followers" do
    field(:actor_uri, :string)
    field(:inbox_uri, :string)
    field(:shared_inbox_uri, :string)
    field(:handle, :string)
    field(:name, :string)
    field(:last_checked_at, :naive_datetime)

    belongs_to(:user, Vutuv.Accounts.User)

    timestamps()
  end

  def changeset(%__MODULE__{} = follower, attrs) do
    follower
    |> cast(attrs, [:actor_uri, :inbox_uri, :shared_inbox_uri, :handle, :name])
    |> validate_required([:actor_uri, :inbox_uri])
    |> validate_length(:actor_uri, max: @max_uri)
    |> validate_length(:inbox_uri, max: @max_uri)
    |> validate_length(:shared_inbox_uri, max: @max_uri)
    |> validate_length(:handle, max: @max_display)
    |> validate_length(:name, max: @max_display)
    |> unique_constraint([:user_id, :actor_uri])
  end

  @doc """
  The `@user@host` Fediverse handle to show the member. A best-effort display
  label — the linked `actor_uri` is the canonical target — built by the shared
  `Vutuv.Fediverse.Handle`, so a follower, a reply and a reaction never write
  the same person two different ways on one page.
  """
  def display_handle(%__MODULE__{actor_uri: actor_uri} = follower),
    do: Handle.display(follower.handle, actor_uri)

  @doc """
  The remote server this follower lives on, as the follower browser's Server
  column shows it and as its filter matches it (lowercased host of the actor
  URI, the Elixir twin of the `uri_host` SQL macro in `Vutuv.Fediverse`).
  """
  def host(%__MODULE__{actor_uri: actor_uri}) do
    case URI.parse(actor_uri).host do
      nil -> ""
      host -> String.downcase(host)
    end
  end
end
