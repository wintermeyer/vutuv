defmodule Vutuv.Repo.Migrations.CreateTranslationsAndTranslationJobs do
  use Ecto.Migration

  @moduledoc """
  On-demand post translations (milestone 13): `translations` caches one
  translated rendering per subject and target language, `translation_jobs`
  is the durable work queue behind it (the `image_scans` row-is-the-job
  pattern). A row's subject is exactly ONE of a local post, a cached remote
  post, or a cached remote reply — CHECK-enforced, and the nullable triple
  is confined to `Vutuv.Translations` (the organization milestone showed
  what NULL pairs cost when they leak into ad-hoc joins).

  No backfill and no pre-computation by design: a job exists only because a
  reader asked for that translation. N-1 safe: pure additions.
  """

  @subject_check "num_nonnulls(post_id, remote_post_id, note_id) = 1"

  def change do
    create table(:translations) do
      add(:post_id, references(:posts, on_delete: :delete_all))
      add(:remote_post_id, references(:fediverse_posts, on_delete: :delete_all))
      add(:note_id, references(:fediverse_notes, on_delete: :delete_all))

      add(:target_language, :string, null: false)
      # As the model reported it ("de", "en", or "und" when it could not tell).
      add(:source_language, :string)
      add(:body, :text, null: false)
      # The translated content warning; only remote content carries one.
      add(:summary, :text)
      add(:model, :string)
      # SHA-256 of the source text at translation time (cache invalidation,
      # not privacy — the content is public). A stale hash re-translates on
      # the next request.
      add(:source_sha256, :string, null: false)

      timestamps()
    end

    create(constraint(:translations, :translations_exactly_one_subject, check: @subject_check))

    # One cached translation per subject + target. Three partial indexes
    # because the subject is a nullable triple.
    for column <- [:post_id, :remote_post_id, :note_id] do
      create(
        index(:translations, [column, :target_language],
          unique: true,
          where: "#{column} IS NOT NULL",
          name: :"translations_#{column}_target_index"
        )
      )
    end

    create table(:translation_jobs) do
      add(:post_id, references(:posts, on_delete: :delete_all))
      add(:remote_post_id, references(:fediverse_posts, on_delete: :delete_all))
      add(:note_id, references(:fediverse_notes, on_delete: :delete_all))

      add(:target_language, :string, null: false)
      add(:status, :string, null: false, default: "pending")
      add(:attempts, :integer, null: false, default: 0)
      add(:next_attempt_at, :utc_datetime)
      add(:last_error, :string)

      timestamps()
    end

    create(
      constraint(:translation_jobs, :translation_jobs_exactly_one_subject, check: @subject_check)
    )

    # One OPEN job per subject + target; resolved rows stay as the audit
    # trail of what was requested and how it went.
    for column <- [:post_id, :remote_post_id, :note_id] do
      create(
        index(:translation_jobs, [column, :target_language],
          unique: true,
          where: "#{column} IS NOT NULL AND status IN ('pending', 'running')",
          name: :"translation_jobs_open_#{column}_target_index"
        )
      )
    end

    # The worker's drain query: due pending work, oldest first.
    create(index(:translation_jobs, [:status, :next_attempt_at]))
  end
end
