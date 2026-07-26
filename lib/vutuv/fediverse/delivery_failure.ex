defmodule Vutuv.Fediverse.DeliveryFailure do
  @moduledoc """
  One takedown that never arrived (issue #1102): a `Delete` or a `Flag` that
  exhausted its eight delivery attempts and was dropped from the queue.

  Every outbound activity is best effort — remote deletion is advisory by
  protocol — but there is a difference in kind between the two failures. A
  `Create` that never lands means one post did not travel; a `Delete` that never
  lands means a copy we told a member we had asked to remove is still published
  on somebody else's server. That is a fact an operator has to be able to see, so
  the give-up is written here and shown on `/admin/fediverse` instead of only
  passing through the log.

  Only the withdrawing activity types are recorded (`Vutuv.Fediverse` keeps the
  list); everything else would drown the signal the same way `NoteEvent` refuses
  to record automatic deletions.

  `user_id` is a plain value, not an association, like the other audit ledgers:
  the row must stay readable after the account it names is gone. `object_uri` is
  our own public Note (or actor) URL, so the row carries no content and no
  third-party identifier.
  """

  use VutuvWeb, :model

  schema "fediverse_delivery_failures" do
    field(:activity_type, :string)
    field(:host, :string)
    field(:object_uri, :string)
    field(:user_id, :binary_id)
    field(:attempts, :integer)
    field(:last_error, :string)

    timestamps(updated_at: false)
  end
end
