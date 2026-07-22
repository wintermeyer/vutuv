defmodule Vutuv.Fediverse.Follower do
  @moduledoc """
  A remote (Fediverse) follower of a member: the remote actor's id URI and
  where to deliver (its inbox, plus the server-wide sharedInbox when the
  remote declares one, so a server with many followers gets each post once).
  Rows are written by the inbox on `Follow` and removed on `Undo`; the remote
  actor's own `Update` re-syncs them and its `Delete` removes them, so a
  renamed remote stops showing under its old handle and a deleted one stops
  counting as a follower.
  """

  use VutuvWeb, :model

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
  The `@user@host` Fediverse handle to show the member. Uses the captured
  `handle` (the remote `preferredUsername`) when present, else the last path
  segment of the actor URI; the host is always the actor URI's host. This is a
  best-effort display label — the linked `actor_uri` is the canonical target.
  """
  def display_handle(%__MODULE__{actor_uri: actor_uri} = follower) do
    uri = URI.parse(actor_uri)
    "@#{follower.handle || derive_username(uri)}@#{uri.host}"
  end

  defp derive_username(%URI{path: path}) do
    (path || "")
    |> String.split("/", trim: true)
    |> List.last()
    |> to_string()
    |> String.trim_leading("@")
  end
end
