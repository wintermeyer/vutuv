defmodule Vutuv.Repo.Migrations.CreateReferenceSkillVersions do
  use Ecto.Migration

  @moduledoc """
  The analysis prompt, as fetched. The Arbeitszeugnis check runs on an open
  skill (a ~131 KB Markdown document) maintained in its own repository and
  re-fetched once a day, so the prompt is *data* here, not source.

  Keeping it in a table rather than only in memory buys three things: it
  survives a restart without waiting on GitHub, every `reference_checks` row
  can name the exact prompt that produced it, and an operator can see what is
  currently in force. Rows are kept, not replaced — the history is what makes
  a changed verdict explainable.
  """

  def change do
    create table(:reference_skill_versions) do
      # The `Version:` line the skill declares ("3.0.24"). Advisory only: the
      # sha256 is what identifies a body, because upstream can edit without
      # bumping.
      add(:version, :string)
      add(:sha256, :string, null: false)
      add(:body, :text, null: false)
      # remote | vendored — whether this came from upstream or from the copy
      # shipped in priv/, which is what an installation without outbound
      # network access runs on.
      add(:source, :string, null: false)
      add(:fetched_at, :utc_datetime, null: false)

      timestamps()
    end

    # One row per distinct body. The daily fetch usually returns what we
    # already have, and that is an upsert, not a new row.
    create(unique_index(:reference_skill_versions, [:sha256]))
    create(index(:reference_skill_versions, [:fetched_at]))
  end
end
