defmodule Vutuv.Repo.Migrations.DropJobPostingsAndRecruitingTables do
  use Ecto.Migration

  # The job posting and recruiter (headhunter) feature was removed from the
  # codebase, so its tables go too. `down/0` recreates them in their final
  # shape (creates plus all later alters) to keep the migration reversible.

  def up do
    drop(table(:job_posting_tags))
    drop(table(:job_postings))
    drop(table(:recruiter_subscriptions))
    drop(table(:coupons))
    drop(table(:recruiter_packages))
  end

  def down do
    create table(:recruiter_packages) do
      add(:name, :string)
      add(:description, :string)
      add(:slug, :string)
      add(:locale_id, references(:locales, on_delete: :nothing))
      add(:price, :float)
      add(:currency, :string)
      add(:duration_in_months, :integer)
      add(:auto_renewal, :boolean, default: true)
      add(:offer_begins, :date)
      add(:offer_ends, :date)
      add(:max_job_postings, :integer)
      add(:only_with_coupon, :boolean, default: false)

      timestamps()
    end

    create(unique_index(:recruiter_packages, [:slug]))

    create table(:job_postings) do
      add(:user_id, references(:users, on_delete: :delete_all))
      add(:title, :string)
      add(:description, :string)
      add(:location, :string)
      add(:prerequisites, :string)
      add(:slug, :string)
      add(:open_on, :date)
      add(:closed_on, :date)
      add(:company, :string)
      add(:min_salary, :integer)
      add(:max_salary, :integer)
      add(:currency, :string)
      add(:remote, :boolean)

      timestamps()
    end

    create(unique_index(:job_postings, [:slug]))

    create table(:job_posting_tags) do
      add(:job_posting_id, references(:job_postings, on_delete: :delete_all))
      add(:tag_id, references(:tags, on_delete: :delete_all))
      add(:priority, :integer)

      timestamps()
    end

    create(unique_index(:job_posting_tags, [:job_posting_id, :tag_id]))

    create table(:recruiter_subscriptions) do
      add(:user_id, references(:users, on_delete: :delete_all))
      add(:recruiter_package_id, references(:recruiter_packages, on_delete: :delete_all))
      add(:subscription_begins, :date)
      add(:subscription_ends, :date)
      add(:line1, :string)
      add(:line2, :string)
      add(:street, :string)
      add(:zip_code, :string)
      add(:city, :string)
      add(:country, :string)
      add(:invoice_number, :string)
      add(:invoiced_on, :date)
      add(:paid, :boolean)
      add(:paid_on, :date)
      add(:coupon_code, :string)

      timestamps()
    end

    create(unique_index(:recruiter_subscriptions, [:invoice_number]))

    create table(:coupons) do
      add(:code, :string)
      add(:user_id, :integer)
      add(:recruiter_package_id, :integer)
      add(:amount, :decimal)
      add(:percentage, :integer)
      add(:ends_on, :date)
      add(:valid, :boolean, default: true)

      timestamps()
    end

    create(unique_index(:coupons, [:code]))
  end
end
