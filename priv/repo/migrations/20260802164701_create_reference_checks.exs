defmodule Vutuv.Repo.Migrations.CreateReferenceChecks do
  use Ecto.Migration

  @moduledoc """
  One AI check of one Zeugnis — the durable queue entry and, once finished,
  the stored result. The `image_scans` shape (the row *is* the job) rather
  than a separate results table: a check takes minutes, so the member watches
  the row travel through its states, and the finished row is what the page
  renders afterwards.

  `body_fingerprint` binds a result to the exact text that produced it. Edit
  the Zeugnis and the result is shown as outdated rather than deleted — the
  old reading is still worth seeing, it just no longer describes what is on
  screen.
  """

  def change do
    create table(:reference_checks) do
      add(
        :job_reference_id,
        references(:job_references, on_delete: :delete_all, type: :binary_id),
        null: false
      )

      # Denormalised from the parent so the per-member rate limit and the
      # "my checks" read never need the join, and so a check still knows whom
      # to notify while its parent row is being deleted.
      add(:user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false)

      # pending | running | done | failed | canceled
      add(:status, :string, null: false, default: "pending")
      add(:attempts, :integer, null: false, default: 0)
      add(:next_attempt_at, :utc_datetime)
      # Operator-facing only. Never carries Zeugnis text: the member's document
      # must not leak into a log line or an admin screen.
      add(:last_error, :string)

      # SHA-256 of the analysed body. A result whose fingerprint no longer
      # matches the entry is stale, not wrong.
      add(:body_fingerprint, :string)

      # Which prompt produced this. The skill is re-fetched daily from its
      # upstream repository, so two results months apart can legitimately
      # differ; without these two columns that difference is unexplainable.
      add(:skill_version, :string)
      add(:skill_sha256, :string)
      add(:model, :string)

      # The model's Markdown answer. Rendered through the *sanitising*
      # renderer (VutuvWeb.Markdown), never the trusted one: the Zeugnis text
      # is member input that reaches the prompt, so the answer is untrusted.
      add(:result_markdown, :text)

      # What the run cost. `prompt_tokens` is also the completeness proof:
      # Ollama silently truncates a prompt that exceeds num_ctx (a 35_559-token
      # prompt came back as 16_386 at the 32_768 default, losing half the legal
      # basis while still answering confidently), so the client compares this
      # against what it sent.
      add(:prompt_tokens, :integer)
      add(:output_tokens, :integer)
      add(:duration_ms, :integer)

      add(:queued_at, :utc_datetime)
      add(:started_at, :utc_datetime)
      add(:finished_at, :utc_datetime)

      timestamps()
    end

    create(index(:reference_checks, [:job_reference_id]))
    create(index(:reference_checks, [:user_id]))

    # At most one unfinished check per Zeugnis. Double-clicking "prüfen" must
    # not buy two slots on a queue where each job holds the model for minutes.
    create(
      unique_index(:reference_checks, [:job_reference_id],
        where: "status IN ('pending', 'running')",
        name: :reference_checks_one_open_per_reference_index
      )
    )

    # The worker's own read: due pending work, oldest first.
    create(
      index(:reference_checks, [:next_attempt_at],
        where: "status = 'pending'",
        name: :reference_checks_due_index
      )
    )
  end
end
