defmodule Vutuv.Tags.TagMerge do
  @moduledoc """
  One absorbed tag, written down (issue #1338).

  A merge moves rows people put somewhere on purpose, so it is recorded rather
  than just done: what moved, how much of it, and everything a revert needs.
  `Vutuv.Tags.Merge` is the only writer; the admin screen reads this table as
  the merge history and reverts from it.
  """

  use VutuvWeb, :model

  alias Vutuv.Accounts.User
  alias Vutuv.Tags.Tag

  schema "tag_merges" do
    belongs_to(:canonical_tag, Tag)
    belongs_to(:absorbed_tag, Tag)
    belongs_to(:admin_user, User)

    # Per table, how many rows moved — what the admin screen reports back.
    field(:moved_counts, :map, default: %{})

    # What a revert needs: `"moves"` (ids grouped per table and destination)
    # and `"deletes"` (whole rows, restored verbatim). See `Vutuv.Tags.Merge`.
    field(:undo, :map, default: %{})

    field(:reverted_at, :naive_datetime)

    timestamps()
  end

  def changeset(tag_merge, attrs) do
    tag_merge
    |> cast(attrs, [
      :canonical_tag_id,
      :absorbed_tag_id,
      :admin_user_id,
      :moved_counts,
      :undo,
      :reverted_at
    ])
    |> validate_required([:canonical_tag_id, :absorbed_tag_id])
  end
end
