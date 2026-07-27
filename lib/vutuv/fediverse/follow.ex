defmodule Vutuv.Fediverse.Follow do
  @moduledoc """
  A member here following an account on another network (issue #1160) — the
  mirror image of `Vutuv.Fediverse.Follower`.

  The row is written the moment the member asks, in state `requested`, because
  that is the truth: an ActivityPub `Follow` is a request, and the other side
  decides. An inbound `Accept` naming our `follow_activity_id` flips it to
  `accepted`; a `Reject` deletes it. An account that approves its followers by
  hand can leave a follow `requested` indefinitely, which is why the state is
  shown rather than hidden — "Requested" is a real answer, not a loading
  spinner.

  `follow_activity_id` is the id of the `Follow` we sent and the join between
  the two sides of the handshake. It is unique installation-wide, so one
  server's answer can never seal a different member's follow.
  """

  use VutuvWeb, :model

  @requested "requested"
  @accepted "accepted"
  # The account moved to another server and this follow has been re-pointed at
  # the successor (issue #1168). The row stays until the successor accepts, so a
  # move that is never answered leaves a record of what the member had rather
  # than silently losing it — and `moved` never publishes and never delivers,
  # which is the whole difference from `accepted`.
  @moved "moved"
  @states [@requested, @accepted, @moved]

  # The activity id we mint (actor URL + "#follows/" + the row id) is far
  # shorter than this; the cap is the backstop that keeps the unique btree key
  # inside Postgres' limit.
  @max_uri 2_048

  schema "fediverse_follows" do
    field(:state, :string, default: @requested)
    field(:follow_activity_id, :string)
    field(:muted, :boolean, default: false)

    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:remote_account, Vutuv.Fediverse.RemoteAccount)

    timestamps()
  end

  def changeset(%__MODULE__{} = follow, attrs) do
    follow
    |> cast(attrs, [:state, :follow_activity_id, :muted])
    |> validate_required([:state, :follow_activity_id])
    |> validate_inclusion(:state, @states)
    |> validate_length(:follow_activity_id, max: @max_uri, count: :bytes)
    |> unique_constraint([:user_id, :remote_account_id])
    |> unique_constraint(:follow_activity_id)
  end

  @doc """
  The transition an inbound `Accept` performs. Through the changeset rather than
  a bare `Ecto.Changeset.change/2`, so the one write that ever moves a follow
  out of `requested` is the one write `validate_inclusion/3` still guards.
  """
  def accept(%__MODULE__{} = follow), do: changeset(follow, %{state: @accepted})

  @doc "The closed set of states a follow can be in."
  def states, do: @states

  @doc "Whether the other side has confirmed this follow."
  def accepted?(%__MODULE__{state: @accepted}), do: true
  def accepted?(%__MODULE__{}), do: false

  @doc "The state of a follow whose account moved and which has been re-pointed."
  def moved, do: @moved

  @doc "Whether this follow is a husk left behind by a move."
  def moved?(%__MODULE__{state: @moved}), do: true
  def moved?(%__MODULE__{}), do: false
end
