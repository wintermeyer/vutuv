defmodule Vutuv.Repo.Migrations.CreatePublications do
  use Ecto.Migration

  def change do
    create table(:publications) do
      add(:user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false)
      add(:title, :string, null: false)
      # Co-authors as they appear on the paper — free text, because author
      # lists run long and carry initials, "et al." and institutions.
      add(:authors, :text)
      add(:publisher, :string)
      add(:published_month, :integer)
      add(:published_year, :integer)
      # A DOI link or the publisher's page. `text` like the other link columns
      # that hold somebody else's address (bounded by the changeset at 2048).
      add(:url, :text)
      add(:description, :text)
      add(:slug, :string)
      add(:announce_to_followers?, :boolean, null: false, default: false)

      timestamps()
    end

    create(index(:publications, [:user_id]))
    create(unique_index(:publications, [:slug]))

    # The CV-update feed (issue #980) reads announced entries newest first.
    create(
      index(:publications, [:user_id, :inserted_at],
        where: ~s("announce_to_followers?"),
        name: :publications_announced_index
      )
    )
  end
end
