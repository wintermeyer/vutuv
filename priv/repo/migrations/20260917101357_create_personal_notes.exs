defmodule Vutuv.Repo.Migrations.CreatePersonalNotes do
  @moduledoc """
  What a member writes down about somebody else, for their eyes only
  (`Vutuv.PersonalNotes`).

  One row per note, not one per pair: a member keeps as many as they like about
  the same account, each dated by when it was written.

  New table, so N-1 compatible: the running release neither reads nor writes it.
  """
  use Ecto.Migration

  def change do
    create table(:personal_notes) do
      # The author, and the only account that ever reads the row.
      add(:user_id, references(:users, on_delete: :delete_all), null: false)

      # Who the note is about, in the three shapes an account can have here: a
      # member, a page, an account on another network. Exactly one is set,
      # CHECK-enforced below. Every one cascades, because a note about an
      # account that no longer exists is a note nobody asked us to keep: a
      # member's deletion, a page's, and a remote account's own `Delete` (or its
      # server being blocked) all take the notes about it along.
      add(:subject_user_id, references(:users, on_delete: :delete_all))
      add(:subject_organization_id, references(:organizations, on_delete: :delete_all))

      add(
        :subject_remote_account_id,
        references(:fediverse_remote_accounts, on_delete: :delete_all)
      )

      # Markdown, capped at 10,000 characters by the changeset.
      add(:body, :text, null: false)

      # Set when the body changes after the note was written. The note keeps its
      # place in the list either way: the date that counts is when it was taken.
      add(:edited_at, :utc_datetime)

      timestamps()
    end

    create(
      constraint(:personal_notes, :exactly_one_subject,
        check: """
        (subject_user_id IS NOT NULL)::int
          + (subject_organization_id IS NOT NULL)::int
          + (subject_remote_account_id IS NOT NULL)::int = 1
        """
      )
    )

    create(
      constraint(:personal_notes, :no_self_note, check: "user_id <> subject_user_id")
    )

    # The overview: one member's notes, newest first (UUID v7 ids sort by
    # creation), and the author-side cascade.
    create(index(:personal_notes, [:user_id, :id]))

    # One per subject column, leading with the subject so a deletion's cascade
    # finds its rows, and partial because two of the three are NULL on every row.
    create(
      index(:personal_notes, [:subject_user_id, :user_id],
        where: "subject_user_id IS NOT NULL"
      )
    )

    create(
      index(:personal_notes, [:subject_organization_id, :user_id],
        where: "subject_organization_id IS NOT NULL"
      )
    )

    create(
      index(:personal_notes, [:subject_remote_account_id, :user_id],
        where: "subject_remote_account_id IS NOT NULL"
      )
    )
  end
end
