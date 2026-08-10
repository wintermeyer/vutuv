defmodule Vutuv.Repo.Migrations.AddTagMergeCandidates do
  use Ecto.Migration

  # The queue behind the assisted pass (issue #1338): pairs of tags that might
  # be one topic, for a human to approve or reject.
  #
  # Candidates are generated cheaply and deterministically and only then judged
  # by the local model, so `generator` says which rule produced the pair and
  # `judged_at` whether a model has looked at it yet — an installation with no
  # Ollama still fills the queue and administers it by hand.
  #
  # The pair is stored with the smaller id first, like `tag_distinctions`, so a
  # pair is one row however it was generated. A decision empties the row: an
  # approval leaves a `tag_merges` entry behind, a rejection a `tag_distinctions`
  # one, and either way the pair is not proposed again.
  def change do
    create table(:tag_merge_candidates, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:tag_a_id, references(:tags, type: :binary_id, on_delete: :delete_all), null: false)
      add(:tag_b_id, references(:tags, type: :binary_id, on_delete: :delete_all), null: false)

      # The model's proposal, all three nil until it has judged: which of the
      # two should survive, what kind of name the other becomes, and one line
      # saying why. A human still decides.
      add(:suggested_canonical_id, references(:tags, type: :binary_id, on_delete: :nilify_all))
      add(:kind, :string)
      add(:reason, :text)
      add(:judged_at, :naive_datetime)

      # Which rule found the pair, and how many members it would touch — the
      # queue is ordered by that, so the consequential merges are looked at
      # first.
      add(:generator, :string, null: false)
      add(:members_affected, :integer, null: false, default: 0)

      timestamps()
    end

    create(unique_index(:tag_merge_candidates, [:tag_a_id, :tag_b_id]))
    create(index(:tag_merge_candidates, [:tag_b_id]))
    create(index(:tag_merge_candidates, [:members_affected]))
  end
end
