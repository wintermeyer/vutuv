defmodule Vutuv.Repo.Migrations.AddFrozenAtToAttachments do
  use Ecto.Migration

  # A file becomes a content type of its own in the moderation case machinery
  # (issue #2109), so it needs the column every other reportable thing already
  # has: the record that a copyright case is holding it.
  #
  # `:naive_datetime` rather than the `:utc_datetime` its two pipeline columns
  # use, and that is not cosmetic — `Vutuv.Moderation`'s generic
  # `content_hidden?/2` and `uphold_content_effect/2` clauses pattern-match on
  # `%{frozen_at: %NaiveDateTime{}}`, so a UTC stamp here would leave a held
  # file reading back as still visible to its own reporter's outcome notice.
  # Every other `frozen_at` in the schema (posts, messages, users,
  # organizations, images) is naive for the same reason.
  #
  # One nullable column, so the release still serving traffic during the
  # blue/green window neither reads nor writes it (N-1). The partial index is
  # what `Vutuv.Attachments.reconcile_holds/0` reads every fifteen minutes:
  # almost always empty, and never a sequential scan of the whole table.
  def change do
    alter table(:attachments) do
      add(:frozen_at, :naive_datetime)
    end

    create(
      index(:attachments, [:frozen_at],
        where: "frozen_at IS NOT NULL",
        name: :attachments_frozen_index
      )
    )
  end
end
