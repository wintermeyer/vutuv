defmodule Vutuv.Repo.Migrations.CreateOrganizationScreenshots do
  use Ecto.Migration

  # The durable queue + attachment record for an organization page's homepage
  # screenshot (Vutuv.Organizations.Screenshots): one row per organization that
  # names a website. A `pending`/`capturing`/`failed` row is a queued job the
  # worker drains; a `ready` row carries the stored capture. Additive only, so
  # the currently deployed release keeps working (N-1 compatible).
  def change do
    create table(:organization_screenshots) do
      add(:organization_id, references(:organizations, on_delete: :delete_all), null: false)

      # The captured URL — a copy of `organizations.website_url` at capture time,
      # so a job knows what it shot without re-reading the page it belongs to.
      # `text` like the post queue's column: Ecto enforces no column limit and a
      # homepage URL can carry a long path.
      add(:url, :text, null: false)
      add(:status, :string, null: false, default: "pending")
      # The stored "<hash><ext>" (Vutuv.Screenshot), nil until ready.
      add(:screenshot, :string)
      add(:width, :integer)
      add(:height, :integer)
      add(:attempts, :integer, null: false, default: 0)
      add(:next_attempt_at, :utc_datetime)
      add(:last_error, :string)
      add(:captured_at, :utc_datetime)
      # AI image moderation state (Vutuv.Moderation.ImageScans): a fresh capture
      # is held back ("pending") until the scan releases it.
      add(:moderation, :string)

      timestamps()
    end

    # One screenshot per organization — the row is refreshed in place when the
    # page's website changes, never duplicated.
    create(unique_index(:organization_screenshots, [:organization_id]))
    # The poller claims due rows by (status, next_attempt_at).
    create(index(:organization_screenshots, [:status, :next_attempt_at]))
  end
end
