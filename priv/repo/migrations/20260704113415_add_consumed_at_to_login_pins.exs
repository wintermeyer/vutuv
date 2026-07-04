defmodule Vutuv.Repo.Migrations.AddConsumedAtToLoginPins do
  use Ecto.Migration

  # Records when a one-time PIN was successfully used, so a re-submission of an
  # already-consumed PIN (a double-submit / back-navigation of the classic PIN
  # form) can be told apart from a genuinely timed-out one. Before this, both
  # collapsed to `minted_at = nil` and were reported to the member as "PIN
  # expired" — even right after a successful login (issue #839).
  #
  # Plain nullable column addition: N-1 compatible, safe in a single deploy. The
  # currently deployed release simply ignores it.
  def change do
    alter table(:login_pins) do
      add(:consumed_at, :naive_datetime)
    end
  end
end
