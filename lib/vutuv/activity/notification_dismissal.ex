defmodule Vutuv.Activity.NotificationDismissal do
  @moduledoc """
  One member has seen one notification — the per-event read mark behind
  `Vutuv.Activity.mark_notification_seen/3`, whose docs say why it exists.

  `kind` and `source_id` together name the event: the notification kind (or,
  for the two families `report_protection` emits, the pseudo-kind
  `"report_protection_restored"`) and the id of the row the feed derives that
  event from — the follow, the like, the endorsement, the scan. That pair is
  also the feed item's own id (`Vutuv.Activity.event_id/2`), so the
  notifications page renders the row as read from the same two columns.

  Nothing ever updates a row: it is written once and dropped when the read
  marker moves past it.
  """

  use VutuvWeb, :model

  schema "notification_dismissals" do
    field(:kind, :string)
    field(:source_id, Vutuv.UUIDv7)

    belongs_to(:user, Vutuv.Accounts.User)

    timestamps(updated_at: false)
  end
end
