defmodule Vutuv.Repo.Migrations.AddNotificationPostLinesToUsers do
  use Ecto.Migration

  # How many lines of a quoted post the /notifications rows show for this
  # reader. Nullable with no DB default, like every other Vutuv.Prefs column:
  # NULL means "inherit the installation default" (/admin/preferences), so a
  # member who never touched it keeps following the admin's choice. A plain
  # additive column, so it is N-1 compatible on its own.
  def change do
    alter table(:users) do
      add(:notification_post_lines, :integer)
    end
  end
end
