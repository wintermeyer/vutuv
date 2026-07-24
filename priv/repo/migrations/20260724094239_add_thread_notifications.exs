defmodule Vutuv.Repo.Migrations.AddThreadNotifications do
  use Ecto.Migration

  # Thread notifications opt-out (issue #1025). Since #1010 a reply anywhere in
  # a thread a member wrote in reaches every participant (the feed's "thread"
  # kind). It is the point of a live discussion, but a busy thread can get
  # loud, so this gives each member one switch to turn it off — shaped exactly
  # like `cv_update_notifications?` (#980), the only other in-app kind a member
  # can silence.
  #
  # Default true: an opt-out, not an opt-in. The `reply` kind (a direct answer
  # to your own post) is unaffected and stays always-on.
  #
  # Plain additive column with a default, so the previous release keeps working
  # untouched during the blue/green window (N-1 safe).
  def change do
    alter table(:users) do
      add(:thread_notifications?, :boolean, null: false, default: true)
    end
  end
end
