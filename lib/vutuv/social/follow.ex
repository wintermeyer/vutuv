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

  import Vutuv.Moderation.Query, only: [account_hidden: 1, account_confirmed_row: 1]

  schema "follows" do
    belongs_to(:follower, Vutuv.Accounts.User)
    belongs_to(:followee, Vutuv.Accounts.User)
    field(:muted, :boolean, default: false)

    timestamps()
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
        order_by: [desc: :inserted_at],
        limit: ^n
      )

    case listed do
      :follower -> Ecto.Query.from([follower: u] in query, where: not account_hidden(u.id))
      :followee -> Ecto.Query.from([followee: u] in query, where: not account_hidden(u.id))
    end
  end
end
