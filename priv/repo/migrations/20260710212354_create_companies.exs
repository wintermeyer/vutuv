defmodule Vutuv.Repo.Migrations.CreateCompanies do
  use Ecto.Migration

  # Verified company pages (issue #929). All additive: new tables plus a nullable
  # reference back to users, so the currently deployed release keeps working
  # while the migration runs (blue/green N-1 rule). Ids are UUID v7 / binary_id
  # via the repo config; no per-column type overrides needed.
  def change do
    create table(:companies) do
      add(:name, :string, null: false)
      add(:slug, :string, null: false)
      # Markdown, rendered NOT-trusted like posts; long prose -> text, max 10_000.
      add(:description, :text)
      add(:website_url, :string)
      # Image tokens (Vutuv.CompanyImageStore); the on-disk dir name, not the row id.
      add(:logo, :string)
      add(:cover, :string)
      add(:street_address, :string, null: false)
      add(:zip_code, :string, null: false)
      add(:city, :string, null: false)
      add(:state, :string)
      # ISO 3166-1 alpha-2 (controlled vocabulary via Vutuv.Countries).
      add(:country, :string, null: false)
      # Machine visibility (owner's choice, both default on): seo? -> noindex +
      # JSON-LD + sitemap; geo? -> agent-format siblings + /llms.txt.
      add(:seo?, :boolean, null: false, default: true)
      add(:geo?, :boolean, null: false, default: true)
      # pending | active | frozen | archived
      add(:status, :string, null: false, default: "pending")
      add(:verified_at, :naive_datetime)
      # Set by the moderation freezer; hides the page from the public.
      add(:frozen_at, :naive_datetime)
      add(:created_by_user_id, references(:users, on_delete: :nilify_all))
      timestamps()
    end

    create(unique_index(:companies, [:slug]))
    create(index(:companies, [:status]))
    create(index(:companies, [:created_by_user_id]))
    # Directory search-as-you-type is over name AND city ("Firmen in Koln").
    create(index(:companies, [:city]))

    create table(:company_domains) do
      add(:company_id, references(:companies, on_delete: :delete_all), null: false)
      add(:domain, :string, null: false)
      add(:primary?, :boolean, null: false, default: false)
      # dns | well_known. Proving control of the DOMAIN (a TXT record or a file
      # under it), never merely an address on it: an e-mail code would let anyone
      # with a @gmail.com address claim the gmail.com page.
      add(:method, :string, null: false)
      # The proof value: the random token expected in the TXT record / file.
      add(:verification_token, :string, null: false)
      add(:verified_at, :naive_datetime)
      add(:last_checked_at, :naive_datetime)
      # When a periodic recheck first fails, the deadline by which the record/
      # file must return before the domain loses verified status (grace period).
      add(:grace_deadline_at, :naive_datetime)
      timestamps()
    end

    # The anti-squatting anchor: one verified domain belongs to exactly one
    # company (exact host; sub.example.com and example.com are distinct).
    create(unique_index(:company_domains, [:domain]))
    create(index(:company_domains, [:company_id]))
    # Exactly one primary domain per company.
    create(
      unique_index(:company_domains, [:company_id],
        where: ~s|"primary?" = true|,
        name: :company_domains_one_primary_index
      )
    )

    create table(:company_roles) do
      add(:company_id, references(:companies, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      # owner | admin | recruiter (management UI is issue #930).
      add(:role, :string, null: false)
      add(:granted_by_user_id, references(:users, on_delete: :nilify_all))
      timestamps()
    end

    create(unique_index(:company_roles, [:company_id, :user_id]))
    create(index(:company_roles, [:user_id]))

    # The post_images pattern 1:1: uploaded from the description editor, kept
    # pending (company_id NULL) until save, served via a token proxy, purged
    # with the company.
    create table(:company_images) do
      add(:company_id, references(:companies, on_delete: :delete_all))
      # nilify (not delete) on user deletion: a company logo is owned by the
      # page, so it must survive the uploader deleting their account.
      add(:user_id, references(:users, on_delete: :nilify_all))
      add(:token, :string, null: false)
      add(:alt, :string, null: false, default: "")
      add(:position, :integer, null: false, default: 0)
      add(:width, :integer, null: false)
      add(:height, :integer, null: false)
      add(:content_type, :string, null: false)
      add(:size_bytes, :integer, null: false)
      timestamps()
    end

    create(unique_index(:company_images, [:token]))
    create(index(:company_images, [:company_id]))
    create(index(:company_images, [:inserted_at], where: "company_id IS NULL"))

    # Engagement join tables (shared building block): like count is public,
    # bookmarks are private. Both cascade on company or user deletion.
    for table_name <- [:company_likes, :company_bookmarks] do
      create table(table_name) do
        add(:company_id, references(:companies, on_delete: :delete_all), null: false)
        add(:user_id, references(:users, on_delete: :delete_all), null: false)
        timestamps()
      end

      create(unique_index(table_name, [:company_id, :user_id]))
      # Backs the member's saved-items hub (/bookmarks, /likes).
      create(index(table_name, [:user_id, :inserted_at]))
      create(index(table_name, [:company_id]))
    end
  end
end
