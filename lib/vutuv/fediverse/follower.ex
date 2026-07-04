defmodule Vutuv.Fediverse.Follower do
  @moduledoc """
  A remote (Fediverse) follower of a member: the remote actor's id URI and
  where to deliver (its inbox, plus the server-wide sharedInbox when the
  remote declares one, so a server with many followers gets each post once).
  Rows are written by the inbox on `Follow` and removed on `Undo`.
  """

  use VutuvWeb, :model

  # Remote URIs are unbounded in theory; cap generously (they are `text`
  # columns) so a hostile payload cannot store megabytes.
  @max_uri 2_048

  schema "fediverse_followers" do
    field(:actor_uri, :string)
    field(:inbox_uri, :string)
    field(:shared_inbox_uri, :string)

    belongs_to(:user, Vutuv.Accounts.User)

    timestamps()
  end

  def changeset(%__MODULE__{} = follower, attrs) do
    follower
    |> cast(attrs, [:actor_uri, :inbox_uri, :shared_inbox_uri])
    |> validate_required([:actor_uri, :inbox_uri])
    |> validate_length(:actor_uri, max: @max_uri)
    |> validate_length(:inbox_uri, max: @max_uri)
    |> validate_length(:shared_inbox_uri, max: @max_uri)
    |> unique_constraint([:user_id, :actor_uri])
  end
end
