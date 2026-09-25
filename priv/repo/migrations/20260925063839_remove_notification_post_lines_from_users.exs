defmodule Vutuv.Repo.Migrations.RemoveNotificationPostLinesFromUsers do
  use Ecto.Migration

  # The contract half of retiring the "Lines in notifications" setting: the
  # release before this one (#2299) stopped reading the column, so dropping it
  # now keeps the one-step N-1 rule. A member's chosen value is not kept; the
  # setting did nothing since /notifications shows the feed's cards (#2296).
  # The type on `remove` makes the migration reversible.
  def change do
    alter table(:users) do
      remove(:notification_post_lines, :integer)
    end
  end
end
