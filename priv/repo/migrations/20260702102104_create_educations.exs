defmodule Vutuv.Repo.Migrations.CreateEducations do
  use Ecto.Migration

  def change do
    create table(:educations) do
      add(:user_id, references(:users, on_delete: :delete_all, type: :binary_id))
      add(:school, :string)
      add(:degree, :string)
      add(:field_of_study, :string)
      add(:description, :string)
      add(:start_month, :integer)
      add(:start_year, :integer)
      add(:end_month, :integer)
      add(:end_year, :integer)
      add(:slug, :string)

      timestamps()
    end

    create(index(:educations, [:user_id]))
    create(unique_index(:educations, [:slug]))
  end
end
