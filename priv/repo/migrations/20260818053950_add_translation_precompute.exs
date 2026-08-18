defmodule Vutuv.Repo.Migrations.AddTranslationPrecompute do
  use Ecto.Migration

  @moduledoc """
  Background pre-translation of local posts, and a reader's right of way over
  it.

  `translation_jobs.priority` orders the drain (lower runs first): a reader
  who taps Translate is 0, the background sweeper is 50. The default is the
  **reader** value on purpose — the release that is still serving traffic
  during a blue/green deploy inserts jobs without this column, and every one
  of those is a reader's request.

  `posts.translations_enqueued_at` is the sweeper's own clock: when this post
  was last *considered* for pre-translation, stamped on every outcome
  including the one where there was nothing to do. Without that stamp an
  already-translated post would be due again on the very next round and hold
  the front of every batch forever (the `refresh_counts` starvation lesson).

  N-1 safe: pure additions, no type changes.
  """

  def change do
    alter table(:posts) do
      add(:translations_enqueued_at, :utc_datetime)
    end

    alter table(:translation_jobs) do
      add(:priority, :integer, null: false, default: 0)
    end

    # The sweeper's work list: never-considered posts first (NULLS FIRST),
    # then the longest-unconsidered. Partial, because a post with no declared
    # or detected language is never a candidate.
    create(
      index(:posts, ["translations_enqueued_at ASC NULLS FIRST", "id DESC"],
        where: "language IS NOT NULL",
        name: :posts_translations_enqueued_at_index
      )
    )

    # The drain query: open work, best priority first, oldest first within a
    # priority. Also carries the backlog count that caps the background pile.
    create(
      index(:translation_jobs, [:priority, :inserted_at],
        where: "status IN ('pending', 'running')",
        name: :translation_jobs_open_priority_index
      )
    )
  end
end
