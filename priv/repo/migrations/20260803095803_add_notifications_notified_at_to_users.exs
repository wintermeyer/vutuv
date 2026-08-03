defmodule Vutuv.Repo.Migrations.AddNotificationsNotifiedAtToUsers do
  @moduledoc """
  How far the notification digest has already mailed, per member.

  The notifications feed is **derived** from its source tables — there is no
  notifications table to mark a row in — so "which of these have I already
  told them about" needs a high-water mark of its own, exactly the way
  `conversation_participants.notified_at` carries it for direct messages.

  `Vutuv.Activity.Digest` mails everything newer than the later of this and
  `notifications_read_at`, then stamps it. Two consequences worth naming: a
  member who reads their notifications is never mailed about them afterwards
  (the read marker is already past them), and a crash between sending and
  stamping repeats one digest rather than losing it — the safe direction for
  something whose whole job is not to drop news.

  Nullable: a member who has never been mailed has no mark, and everything
  since their read marker is fair game.
  """

  use Ecto.Migration

  def change do
    alter table(:users) do
      add(:notifications_notified_at, :utc_datetime_usec)
    end
  end
end
