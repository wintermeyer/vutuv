defmodule Vutuv.Repo.Migrations.AddBrowserNotifications do
  use Ecto.Migration

  # Browser notifications (issue #1249): while a member has vutuv open in a tab
  # they are not looking at, a new notification or message can pop up through
  # the Notifications API instead of only moving the tab title.
  #
  # Default false, unlike the other two in-app switches (`cv_update_notifications?`,
  # `thread_notifications?`, both opt-outs). This one is an **opt-in** on purpose:
  # a popup over whatever you are doing is the loudest thing vutuv can do, and
  # switching it on is also what makes the browser ask for permission — so
  # nobody who did not ask for it is ever prompted.
  #
  # Plain additive column with a default, so the previous release keeps working
  # untouched during the blue/green window (N-1 safe).
  def change do
    alter table(:users) do
      add(:browser_notifications?, :boolean, null: false, default: false)
    end
  end
end
