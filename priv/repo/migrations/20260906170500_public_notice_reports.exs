defmodule Vutuv.Repo.Migrations.PublicNoticeReports do
  use Ecto.Migration

  # A report filed by somebody who has no account here (issue #2009): a rights
  # holder who finds their photograph on a post is not a member, and until now
  # the only way in was the Impressum address.
  #
  # `reporter_id` becomes nullable and `reporter_email` stands beside it. The
  # address is stored in the clear on purpose — an admin has to be able to write
  # back to the notifier, and a keyed hash of it would answer no question this
  # table asks. It is never shown to the owner of the reported content.
  #
  # N-1: the release currently serving traffic always sets `reporter_id` and
  # never touches the new columns, so it keeps passing the CHECK below.
  # Dropping NOT NULL does not change a result type, so no cached plan is
  # invalidated the way a varchar → text widen would be.
  def up do
    execute("ALTER TABLE moderation_reports ALTER COLUMN reporter_id DROP NOT NULL")

    alter table(:moderation_reports) do
      # Both bounded by the changeset (255 / 255), matching varchar(255).
      add(:reporter_email, :string)
      add(:reporter_name, :string)

      # The receipt mail's confirmation link. A real random token
      # (`Vutuv.Token.random_token/1`, ~165 bits), so a bare SHA-256 is the
      # right stored form: entropy is what protects it, not a key.
      add(:confirmation_hash, :string)
      add(:confirmed_at, :naive_datetime)
    end

    # Exactly one kind of reporter. Written as a CHECK rather than left to the
    # changeset because everything downstream branches on which of the two it
    # is, and a row that is neither (or both) has no answer.
    create(
      constraint(:moderation_reports, :moderation_reports_one_reporter,
        check: "(reporter_id IS NOT NULL) <> (reporter_email IS NOT NULL)"
      )
    )

    # The member-side twin of this index has existed since the table did:
    # `(case_id, reporter_id)` stops one member filing twice on one case. It
    # does NOT stop an outside notifier, because `(case_id, NULL)` never
    # conflicts with another `(case_id, NULL)` in Postgres — so without this
    # partial index one address could file the same notice as often as it
    # liked, and each copy would count towards the spam auto-defense.
    create(
      unique_index(:moderation_reports, [:case_id, :reporter_email],
        where: "reporter_email IS NOT NULL",
        name: :moderation_reports_case_reporter_email_index
      )
    )

    # The confirmation lookup: one row per token, and the token is what the
    # link carries.
    create(
      unique_index(:moderation_reports, [:confirmation_hash],
        where: "confirmation_hash IS NOT NULL",
        name: :moderation_reports_confirmation_hash_index
      )
    )

    # The trust ladder by confirmed address (`trusted_reporter_emails/1` and
    # the track-record page group on it). Partial, because the overwhelming
    # majority of reports are a member's and carry no address at all.
    create(
      index(:moderation_reports, [:reporter_email],
        where: "reporter_email IS NOT NULL",
        name: :moderation_reports_reporter_email_index
      )
    )
  end

  def down do
    drop(index(:moderation_reports, [:reporter_email], name: :moderation_reports_reporter_email_index))

    drop(
      index(:moderation_reports, [:confirmation_hash],
        name: :moderation_reports_confirmation_hash_index
      )
    )

    drop(
      index(:moderation_reports, [:case_id, :reporter_email],
        name: :moderation_reports_case_reporter_email_index
      )
    )

    drop(constraint(:moderation_reports, :moderation_reports_one_reporter))

    alter table(:moderation_reports) do
      remove(:reporter_email)
      remove(:reporter_name)
      remove(:confirmation_hash)
      remove(:confirmed_at)
    end

    execute("ALTER TABLE moderation_reports ALTER COLUMN reporter_id SET NOT NULL")
  end
end
