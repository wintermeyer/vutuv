defmodule Vutuv.Repo.Migrations.CreateJobPostings do
  use Ecto.Migration

  # Job postings (Vutuv.Jobs, milestone 11, issue #932). Everything is
  # binary_id (UUID v7) via the repo config default. A posting always has one
  # responsible human (user_id, NOT NULL); an optional verified organization
  # (organization_id) attributes it to a page; a free-text hiring_org_name
  # covers unverified employers.
  def change do
    create table(:job_postings) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      # nilify: deleting an organization page must not destroy the posting — it
      # gracefully falls back to a personal posting.
      add(:organization_id, references(:organizations, on_delete: :nilify_all))
      add(:hiring_org_name, :string)

      add(:title, :string, null: false)
      add(:description, :text)

      add(:employment_type, :string, null: false)
      add(:workplace_type, :string, null: false)

      # Structured location. zip/city/country required for onsite AND hybrid,
      # empty for remote; remote_countries required non-empty for remote.
      add(:street_address, :string)
      add(:zip_code, :string)
      add(:city, :string)
      add(:country, :string)
      add(:remote_countries, {:array, :string}, null: false, default: [])
      # Resolved at save time from zip + country via Vutuv.Geo; nil when
      # unresolvable (the posting still publishes).
      add(:lat, :float)
      add(:lon, :float)

      # Salary: whole-unit integers (the #928 model, never decimal). Required
      # to publish except for volunteer postings ("Ehrenamtlich").
      add(:salary_min, :integer)
      add(:salary_max, :integer)
      add(:salary_currency, :string, null: false, default: "EUR")
      add(:salary_period, :string, null: false, default: "year")

      add(:apply_kind, :string, null: false, default: "url")
      add(:apply_url, :string)
      add(:apply_email, :string)

      add(:language, :string, null: false, default: "de")
      add(:slug, :string, null: false)

      # Machine visibility (poster's choice, both default on) and human
      # visibility (everyone/members, default everyone).
      add(:seo?, :boolean, null: false, default: true)
      add(:geo?, :boolean, null: false, default: true)
      add(:visibility, :string, null: false, default: "everyone")

      # Lifecycle: draft → published → expired → closed.
      add(:status, :string, null: false, default: "draft")
      add(:first_published_at, :naive_datetime)
      # Berlin calendar date the posting auto-expires on (published + runtime).
      add(:expires_on, :date)
      add(:closed_at, :naive_datetime)
      add(:close_reason, :string)

      add(:view_count, :integer, null: false, default: 0)
      add(:apply_click_count, :integer, null: false, default: 0)

      # Moderation freeze (report → freeze → case machinery).
      add(:frozen_at, :naive_datetime)

      timestamps()
    end

    create(unique_index(:job_postings, [:slug]))
    create(index(:job_postings, [:user_id]))
    create(index(:job_postings, [:organization_id]))
    # Board listing + nightly sweeper (find published postings whose expiry has
    # passed, and expired ones to demote).
    create(index(:job_postings, [:status, :expires_on]))

    # Tags are the matching fabric between postings and profiles, through the
    # Vutuv.Tags chokepoints. priority splits "Erforderlich" from "Wünschenswert".
    create table(:job_posting_tags) do
      add(:job_posting_id, references(:job_postings, on_delete: :delete_all), null: false)
      add(:tag_id, references(:tags, on_delete: :delete_all), null: false)
      add(:priority, :string, null: false, default: "required")
      timestamps()
    end

    create(unique_index(:job_posting_tags, [:job_posting_id, :tag_id]))
    create(index(:job_posting_tags, [:tag_id]))

    # The post_images pattern 1:1: uploaded from the editor, kept pending
    # (job_posting_id NULL) until save, served via a token proxy, purged with
    # the posting.
    create table(:job_posting_images) do
      add(:job_posting_id, references(:job_postings, on_delete: :delete_all))
      # delete_all like post images: a posting image belongs to the posting, and
      # a pending upload dies with the uploader.
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:token, :string, null: false)
      add(:alt, :string, null: false, default: "")
      add(:position, :integer, null: false, default: 0)
      add(:width, :integer, null: false)
      add(:height, :integer, null: false)
      add(:content_type, :string, null: false)
      add(:size_bytes, :integer, null: false)
      timestamps()
    end

    create(unique_index(:job_posting_images, [:token]))
    create(index(:job_posting_images, [:job_posting_id]))
    create(index(:job_posting_images, [:inserted_at], where: "job_posting_id IS NULL"))

    # Engagement join tables (shared building block): like count is public,
    # bookmarks are private. Both cascade on posting or user deletion.
    for table_name <- [:job_posting_likes, :job_posting_bookmarks] do
      create table(table_name) do
        add(:job_posting_id, references(:job_postings, on_delete: :delete_all), null: false)
        add(:user_id, references(:users, on_delete: :delete_all), null: false)
        timestamps()
      end

      create(unique_index(table_name, [:job_posting_id, :user_id]))
      # Backs the member's saved-items hub (/bookmarks, /likes).
      create(index(table_name, [:user_id, :inserted_at]))
      create(index(table_name, [:job_posting_id]))
    end
  end
end
