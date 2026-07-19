defmodule Vutuv.Repo.Migrations.AddImageModeration do
  use Ecto.Migration

  @moduledoc """
  AI image moderation (the Ollama scan queue): the `image_scans` table is the
  durable queue + audit trail, and every image-bearing row gets a denormalized
  moderation state for the render-path gate.

  Fail-closed by construction: the gallery tables (`post_images`,
  `job_posting_images`, `organization_images`) default their `moderation`
  column to `pending`, so an upload path that forgets to enqueue a scan leaves
  the image invisible (the drift sweep then picks it up) — never visible.

  Everything already on disk is grandfathered as `approved` (a backfill scan
  can be queued later with `mix vutuv.moderation.backfill`). N-1 safe: pure
  additions; rows the previous release inserts during the deploy window get
  the `pending` default and are swept into the queue after the switch.
  """

  def change do
    create table(:image_scans) do
      # avatar | cover | post_image | job_posting_image | organization_image |
      # url_screenshot | post_screenshot
      add(:kind, :string, null: false)
      # The scanned asset: users.id for avatar/cover, otherwise the asset row id.
      add(:subject_id, :binary_id, null: false)
      # Who gets the rejection notice; scans die with the account.
      add(:owner_user_id, references(:users, on_delete: :delete_all), null: false)
      add(:status, :string, null: false, default: "pending")
      # Binds the verdict to the exact scanned bytes: a re-upload during a
      # running scan changes the asset's fingerprint, so a stale verdict is
      # discarded instead of approving bytes it never saw.
      add(:fingerprint, :string)
      add(:attempts, :integer, null: false, default: 0)
      add(:next_attempt_at, :utc_datetime)
      add(:last_error, :string)
      # The model's rejection category ("nudity", "violence", ...) for the notice.
      add(:category, :string)
      add(:model, :string)
      add(:scanned_at, :utc_datetime)

      timestamps()
    end

    # One OPEN scan per asset (the moderation-cases pattern): resolved rows stay
    # as the audit trail of what was rejected/approved and why.
    create(
      index(:image_scans, [:kind, :subject_id],
        unique: true,
        where: "status IN ('pending', 'scanning')",
        name: :image_scans_open_subject_index
      )
    )

    # The worker's drain query: due pending work, oldest first.
    create(index(:image_scans, [:status, :next_attempt_at]))
    # The owner's notification feed derives rejected entries from here.
    create(index(:image_scans, [:owner_user_id, :status]))

    # nil = legacy/no image; new uploads set "pending" explicitly in the same
    # UPDATE that stores the filename.
    alter table(:users) do
      add(:avatar_moderation, :string)
      add(:cover_moderation, :string)
    end

    # Gallery images: DB default "pending" is the fail-closed backstop.
    for table <- [:post_images, :job_posting_images, :organization_images] do
      alter table(table) do
        add(:moderation, :string, null: false, default: "pending")
      end
    end

    # Machine-generated screenshots: nil until a capture is stored.
    alter table(:urls) do
      add(:screenshot_moderation, :string)
    end

    alter table(:post_screenshots) do
      add(:moderation, :string)
    end

    # Grandfather everything that exists today (up direction only; the columns
    # vanish on rollback anyway).
    execute("UPDATE users SET avatar_moderation = 'approved' WHERE avatar IS NOT NULL", "")

    execute("UPDATE users SET cover_moderation = 'approved' WHERE cover_photo IS NOT NULL", "")

    execute("UPDATE post_images SET moderation = 'approved'", "")
    execute("UPDATE job_posting_images SET moderation = 'approved'", "")
    execute("UPDATE organization_images SET moderation = 'approved'", "")

    execute("UPDATE urls SET screenshot_moderation = 'approved' WHERE screenshot IS NOT NULL", "")

    execute("UPDATE post_screenshots SET moderation = 'approved' WHERE status = 'ready'", "")
  end
end
