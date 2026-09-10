defmodule Vutuv.Attachments.Upload do
  @moduledoc """
  One accepted upload's entry in the budget ledger (issue #2104).

  The daily and monthly budgets count **accepted uploads**, not stored bytes,
  which is why this is its own table rather than a sum over `attachments`:
  deleting a file — or having the abandoned-composer sweep take it — must not
  hand the member their megabytes back and let an upload-and-delete loop run
  the disk down.

  The row says nothing about the file. A member, a byte count and a moment is
  all the budget question needs, so that is all it keeps.
  """

  use VutuvWeb, :model

  schema "attachment_uploads" do
    belongs_to(:user, Vutuv.Accounts.User)
    field(:size_bytes, :integer)

    timestamps(updated_at: false)
  end
end
