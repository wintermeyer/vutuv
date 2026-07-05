defmodule Vutuv.Repo.Migrations.CreateLanguages do
  use Ecto.Migration

  def change do
    create table(:languages) do
      add(:user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false)
      # An ISO 639-1 language code ("en", "de"); the display name is derived
      # from Vutuv.Languages, so only the code is stored.
      add(:language_code, :string, null: false)
      # A proficiency level: "native" or a CEFR level (a1..c2). Validated in
      # Vutuv.Profiles.Language, kept as a plain string here.
      add(:proficiency, :string, null: false)

      timestamps()
    end

    create(index(:languages, [:user_id]))
    # One entry per language per member: you list German once, not twice.
    create(unique_index(:languages, [:user_id, :language_code]))
  end
end
