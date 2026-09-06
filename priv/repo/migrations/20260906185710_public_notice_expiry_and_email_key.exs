defmodule Vutuv.Repo.Migrations.PublicNoticeExpiryAndEmailKey do
  use Ecto.Migration

  # Two holes the independent review found in the public notice form (#2009).
  #
  # **The address a limit is counted against is not the address a mail goes
  # to.** `victim+one@example.com` and `victim+two@example.com` are one mailbox
  # at every provider that reads the `+` tag, and at Gmail so is `v.ictim@`;
  # each spelling was taking a fresh rate-limit bucket and a fresh row past the
  # `(case_id, reporter_email)` index, so both caps came off. `reporter_email`
  # stays exactly as it was typed, because that is what an admin writes back
  # to; the canonical form goes in `reporter_email_key` and carries the
  # uniqueness instead (`Vutuv.Moderation.Report.canonical_email/1`).
  #
  # N-1: the release currently serving traffic writes neither column, and the
  # old index it does rely on stays where it is, so its inserts keep working.
  # The new index is partial on a column only the new release fills, so it
  # cannot reject anything the old one writes either.
  def up do
    alter table(:moderation_reports) do
      add(:reporter_email_key, :string)
      # A confirmation link that never dies is a takedown anybody can trigger
      # a year later from a forwarded mail. The deadline is the row's, not a
      # sweeper's guess, so an expired notice reads as expired even if nothing
      # has swept yet.
      add(:confirmation_expires_at, :naive_datetime)
    end

    create(
      unique_index(:moderation_reports, [:case_id, :reporter_email_key],
        where: "reporter_email_key IS NOT NULL",
        name: :moderation_reports_case_reporter_email_key_index
      )
    )

    # The sweeper's due list: unconfirmed notices past their deadline. Partial,
    # because a member's report has no deadline and neither has a confirmed
    # notice, so the index holds only the rows the sweep can act on.
    create(
      index(:moderation_reports, [:confirmation_expires_at],
        where: "confirmed_at IS NULL AND confirmation_expires_at IS NOT NULL",
        name: :moderation_reports_unconfirmed_due_index
      )
    )
  end

  def down do
    drop(
      index(:moderation_reports, [:confirmation_expires_at],
        name: :moderation_reports_unconfirmed_due_index
      )
    )

    drop(
      index(:moderation_reports, [:case_id, :reporter_email_key],
        name: :moderation_reports_case_reporter_email_key_index
      )
    )

    alter table(:moderation_reports) do
      remove(:reporter_email_key)
      remove(:confirmation_expires_at)
    end
  end
end
