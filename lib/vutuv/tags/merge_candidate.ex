defmodule Vutuv.Tags.MergeCandidate do
  @moduledoc """
  A pair of tags that might be one topic, waiting for a human (issue #1338).

  Written by `Vutuv.Tags.Assistant` and emptied by a decision on
  `/admin/tag_merges`: approving leaves a `Vutuv.Tags.TagMerge` behind, rejecting
  a `Vutuv.Tags.TagDistinction`, and either way the pair is never proposed again.

  `suggested_canonical_id`, `kind` and `reason` are the local model's proposal
  and stay `nil` until it has judged the pair — the queue is usable without one.
  """

  use VutuvWeb, :model

  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.TagDistinction

  @kinds Tag.alias_kinds()

  schema "tag_merge_candidates" do
    belongs_to(:tag_a, Tag)
    belongs_to(:tag_b, Tag)
    belongs_to(:suggested_canonical, Tag)

    field(:kind, :string)
    field(:reason, :string)
    field(:judged_at, :naive_datetime)
    field(:generator, :string)
    field(:members_affected, :integer, default: 0)

    timestamps()
  end

  def changeset(candidate, attrs) do
    candidate
    |> cast(attrs, [
      :tag_a_id,
      :tag_b_id,
      :suggested_canonical_id,
      :kind,
      :reason,
      :judged_at,
      :generator,
      :members_affected
    ])
    |> validate_required([:tag_a_id, :tag_b_id, :generator])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:reason, max: 1_000)
    |> unique_constraint([:tag_a_id, :tag_b_id])
  end

  @doc "The pair in stored order, so one pair is one row (see `TagDistinction`)."
  defdelegate ordered(a, b), to: TagDistinction
end
