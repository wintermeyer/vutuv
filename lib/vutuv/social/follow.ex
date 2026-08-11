defmodule Vutuv.Social.Follow do
  @moduledoc """
  A one-directional follow edge: `follower_id` follows `followee_id`. Anyone may
  follow anyone, with no approval — it is a subscription that decides whose
  posts land in your feed, and it is the *only* social action there is. A
  **mutual** follow (both directions present) is what the app calls "vernetzt"
  (connected); it is derived from these two edges, not a separate record.

  `muted` is a per-follow flag the follower owns: a muted follow keeps the
  relationship (and any mutual "vernetzt" status) but drops the followee's posts
  out of the follower's feed. It is silent and one-directional — unlike a block,
  which severs everything both ways.
  """

  use VutuvWeb, :model

  import Vutuv.Moderation.Query, only: [account_hidden_row: 1, account_confirmed_row: 1]

  schema "follows" do
    # The follower is a member OR an organization (issue #1336), CHECK-enforced
    # to exactly one — the same nullable pair the followee side carries, so the
    # table has four legal combinations. Nothing writes an organization follower
    # yet: the column shipped ahead of its writer so every reader could be
    # taught about the row shape first.
    belongs_to(:follower, Vutuv.Accounts.User)
    belongs_to(:follower_organization, Vutuv.Organizations.Organization)
    # The followee is a member OR an organization (issue #1336), CHECK-enforced
    # to exactly one. The follower stays a member: an organization *following*
    # somebody is a later step and needs its own decisions about whose feed and
    # whose notifications such a follow would feed.
    belongs_to(:followee, Vutuv.Accounts.User)
    belongs_to(:followee_organization, Vutuv.Organizations.Organization)
    field(:muted, :boolean, default: false)

    timestamps()
  end

  @doc """
  A follow of an organization page. Its own changeset rather than a widened
  `changeset/2`, because the two have different required fields and different
  unique constraints — and one cast that accepted either would also accept both
  or neither, leaving only the database to catch it.
  """
  def organization_changeset(model, params \\ %{}) do
    model
    |> cast(params, [:follower_id, :followee_organization_id, :muted])
    |> validate_required([:follower_id, :followee_organization_id])
    |> unique_constraint([:follower_id, :followee_organization_id],
      message: "You're already following this organization."
    )
    |> foreign_key_constraint(:followee_organization_id)
  end

  @doc """
  Flips the follower's own mute flag on a row that already exists.

  Its own changeset because `changeset/2` re-validates the identity columns, and
  an organization follow legitimately has no `followee_id` — so muting a page
  raised `Ecto.InvalidChangesetError`, i.e. a 500 on `PUT /follows/:id/mute`,
  which is reachable with any follow id the member owns. Nothing here may cast
  an identity column: who follows whom is not what a mute changes.
  """
  def mute_changeset(model, params \\ %{}) do
    model
    |> cast(params, [:muted])
    |> validate_required([:muted])
  end

  @required_fields ~w(follower_id followee_id)a
  @optional_fields ~w(muted)a

  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_not_following_self
    |> unique_constraint(:follower_id_followee_id,
      message: "You're already following this person."
    )
    # A valid-but-nonexistent followee id returns a changeset error instead of
    # raising Ecto.ConstraintError on insert. The FK names are still
    # `connections_*` — the table was renamed from `connections` to `follows`
    # and Postgres keeps constraint names across a table rename.
    |> foreign_key_constraint(:followee_id, name: "connections_followee_id_fkey")
    |> foreign_key_constraint(:follower_id, name: "connections_follower_id_fkey")
  end

  defp validate_not_following_self(
         %{changes: %{followee_id: same, follower_id: same}} = changeset
       ) do
    changeset
    |> add_error(:follower_id, "Cannot follow yourself")
  end

  defp validate_not_following_self(changeset), do: changeset

  @doc """
  The page query behind the public follow lists: newest first, both ends
  activated (nil covers legacy rows predating the flag), and the `listed`
  person — `:follower` on a followers page, `:followee` on a following
  page — not hidden by moderation. The hidden gate deliberately skips the
  other end: that is the page owner, who may be viewing their own lists
  through the moderation bypass while frozen.
  """
  def latest(n, listed) when listed in [:follower, :followee] do
    query =
      Ecto.Query.from(fl in __MODULE__,
        join: fe in assoc(fl, :followee),
        as: :followee,
        join: fr in assoc(fl, :follower),
        as: :follower,
        where:
          account_confirmed_row(fe) and
            account_confirmed_row(fr),
        # The id tiebreaker keeps offset pagination stable when two follows
        # share the same second (timestamps have second precision).
        order_by: [desc: :inserted_at, desc: :id],
        limit: ^n
      )

    # `account_hidden_row/1`, not the correlated `account_hidden/1`: both users
    # rows are already joined above, so the row-bound twin reads the columns
    # the planner has instead of running an EXISTS per candidate row — and it
    # puts the whole gate (confirmed AND not hidden) in one predicate, which is
    # what lets `users_visible_index` apply.
    case listed do
      :follower -> Ecto.Query.from([follower: u] in query, where: not account_hidden_row(u))
      :followee -> Ecto.Query.from([followee: u] in query, where: not account_hidden_row(u))
    end
  end
end
