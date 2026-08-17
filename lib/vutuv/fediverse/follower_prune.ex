defmodule Vutuv.Fediverse.FollowerPrune do
  @moduledoc """
  One remote follower dropped because their account no longer exists (issue
  #1072): `Vutuv.Fediverse.prune_due_followers/0` re-fetched the actor document
  and the remote server answered `404` or `410`.

  The row records **who lost a follower, from which server, on which evidence**
  — a member, a page or a topic — and nothing about the person who left.
  Storing the actor URI here would
  undo the very thing the pruning is for: not holding an online identifier of
  somebody who deleted their account. What is left is what the nightly
  Tagesbericht needs, so a mass-prune (a whole server answering 410 after a
  botched migration, say) is visible the next morning instead of silent.
  """

  use VutuvWeb, :model

  # Hostnames max out at 253 characters; the column is the usual varchar(255).
  @max_host 253

  # The only two answers that mean "this account is gone" (see the module doc of
  # Vutuv.Fediverse.FollowerPruner for why nothing else prunes).
  @statuses [404, 410]

  schema "fediverse_follower_prunes" do
    field(:host, :string)
    field(:status, :integer)

    # Who lost the follower: a member, a page (issue #1334) or a topic
    # (issue #1330), CHECK-enforced to exactly one — the same triple
    # `Vutuv.Fediverse.Follower` carries, because a prune mirrors a follower.
    belongs_to(:user, Vutuv.Accounts.User)
    belongs_to(:organization, Vutuv.Organizations.Organization)
    belongs_to(:tag, Vutuv.Tags.Tag)

    timestamps()
  end

  def changeset(%__MODULE__{} = prune, attrs) do
    prune
    |> cast(attrs, [:host, :status])
    |> validate_required([:host, :status])
    |> validate_length(:host, max: @max_host)
    |> validate_inclusion(:status, @statuses)
  end
end
