defmodule Vutuv.Repo.Migrations.CreateJobPostingTag do
  use Ecto.Migration

  def change do
    create table(:job_posting_tags) do
      add :job_posting_id, references(:job_postings, on_delete: :delete_all)
      add :tag_id, references(:tags, on_delete: :delete_all)
      add :priority, :integer

      timestamps()
    end
    create unique_index(:job_posting_tags, [:job_posting_id, :tag_id], unique: true)
  end
end
