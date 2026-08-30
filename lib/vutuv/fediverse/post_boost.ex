defmodule Vutuv.Fediverse.PostBoost do
  @moduledoc """
  A post an account somebody here follows has re-shared (issue #1167).

  The inbound mirror of `Vutuv.Fediverse.PostRepost`: that one is a member here
  sharing something outward, this one is somebody out there sharing something
  their followers here expect to see. A large share of what any account
  contributes is boosts, so a feed that showed only their own writing showed a
  fraction of them.

  The thing boosted is one of two, and exactly one of the fields is set:

    * `remote_post_id` — a cached post from another network. Its author may live
      on a **third** server we have never spoken to, so storing it means
      dereferencing the announced object: a signed, SSRF-fenced, size-capped GET
      under a per-host budget, refused outright for a blocked host and for
      anything not public or unlisted.
    * `post_id` — a **vutuv member's** own post. No fetch at all: we wrote it.
      This is how members get discovered through the outside network, and it is
      the case worth having no network cost.

  `activity_id` is the `Announce`'s own id, which is what an `Undo(Announce)`
  names. Matching on actor and object instead would work for most
  implementations and quietly not for one that boosts the same post twice.

  The row buys nobody extra retention: a cached copy lives under the ordinary
  six-month clock. What it does is give that copy a reason to be here while
  nobody follows its author — the boost *is* the reason — so the unfollowed
  purge spares a post something still holds.
  """

  use VutuvWeb, :model

  import Vutuv.ChangesetHelpers, only: [scrub_nul: 1]

  # Remote URIs are unbounded in theory; capped in bytes like every other one
  # here, so a hostile value fails the changeset rather than the insert.
  @max_uri_bytes 2_048

  schema "fediverse_post_boosts" do
    belongs_to(:remote_account, Vutuv.Fediverse.RemoteAccount)
    belongs_to(:remote_post, Vutuv.Fediverse.RemotePost)
    belongs_to(:post, Vutuv.Posts.Post)

    field(:activity_id, :string)
    field(:announced_at, :utc_datetime)

    timestamps(updated_at: false)
  end

  def changeset(%__MODULE__{} = boost, attrs) do
    boost
    |> cast(attrs, [:remote_post_id, :post_id, :activity_id, :announced_at])
    |> scrub_nul()
    # `activity_id` is required, not merely capped: it is the only thing an
    # `Undo(Announce)` can match on, so a row without one could never be
    # withdrawn and would stand until its post or its account went.
    |> validate_required([:activity_id, :announced_at])
    |> validate_length(:activity_id, max: @max_uri_bytes, count: :bytes)
    |> unique_constraint([:remote_account_id, :remote_post_id],
      name: :fediverse_post_boosts_remote_index
    )
    |> unique_constraint([:remote_account_id, :post_id],
      name: :fediverse_post_boosts_local_index
    )
  end
end
