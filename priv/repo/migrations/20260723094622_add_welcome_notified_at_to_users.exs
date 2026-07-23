defmodule Vutuv.Repo.Migrations.AddWelcomeNotifiedAtToUsers do
  use Ecto.Migration

  # When the account confirmed its very first login PIN — the moment a sign-up
  # becomes a real member. It is the timestamp of the "your username is @handle"
  # welcome note in the notifications feed (`Vutuv.Activity`), and NULL means
  # "no such note": every account that predates this feature keeps a clean feed
  # rather than being handed a retroactive welcome years after the fact.
  #
  # A plain nullable addition, so the currently deployed release keeps working
  # unchanged (N-1).
  def change do
    alter table(:users) do
      add(:welcome_notified_at, :naive_datetime)
    end
  end
end
