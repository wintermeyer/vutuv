defmodule Vutuv.Repo.Migrations.AddTagMerges do
  use Ecto.Migration

  # Issue #1338: absorbing a tag moves rows that people put there deliberately —
  # the tag on their profile, the vouches under it, the posts they filed. An
  # unreviewable merge is worse than a duplicate, so every merge is written down
  # and can be taken back.
  #
  # `undo` carries what a revert needs and nothing else: the ids of the rows
  # that moved (grouped per table, so a big merge is a few arrays and not a few
  # thousand objects) and the full content of the rows that had to be dropped
  # because their owner already held the surviving tag. Those are re-inserted
  # verbatim, id and all, via `jsonb_populate_record` — same row, not a copy of
  # it, so anything pointing at it (an endorsement) lands where it was.
  #
  # `tag_distinctions` is the other half of the same story: a pair a human has
  # looked at and called two different topics never comes back as a candidate.
  def change do
    create table(:tag_merges, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:canonical_tag_id, references(:tags, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:absorbed_tag_id, references(:tags, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      # Who did it. Nilified rather than cascading: the ledger outlives the
      # admin account, the same way the moderation trail does.
      add(:admin_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))

      add(:moved_counts, :map, null: false, default: %{})
      add(:undo, :map, null: false, default: %{})
      add(:reverted_at, :naive_datetime)

      timestamps()
    end

    create(index(:tag_merges, [:canonical_tag_id]))
    create(index(:tag_merges, [:absorbed_tag_id]))

    create table(:tag_distinctions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:tag_a_id, references(:tags, type: :binary_id, on_delete: :delete_all), null: false)
      add(:tag_b_id, references(:tags, type: :binary_id, on_delete: :delete_all), null: false)
      add(:admin_user_id, references(:users, type: :binary_id, on_delete: :nilify_all))

      timestamps()
    end

    # The pair is stored with the smaller id first, so "these two are different
    # topics" is one fact rather than two, whichever way round it is stated.
    create(unique_index(:tag_distinctions, [:tag_a_id, :tag_b_id]))
    create(index(:tag_distinctions, [:tag_b_id]))
  end
end
