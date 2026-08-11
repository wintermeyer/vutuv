defmodule Vutuv.Repo.Migrations.AddActivityReadAtToOrganizations do
  @moduledoc """
  Issue #1336: an organization's activity has **one** read marker, shared by
  everybody on its team, rather than one per person.

  That is the part the issue calls subtle, and it is a different model rather
  than a wider one: "read" here means *somebody* read it, not that everybody
  did. Which is exactly why this is a column on the page and not a row per
  member — the shape of the storage is the decision.

  It mirrors `users.notifications_read_at` (one timestamp, everything older
  counts as read), so the two sides of the app answer "what is new" the same
  way and no second mechanism has to be learned.
  """
  use Ecto.Migration

  def change do
    alter table(:organizations) do
      add(:activity_read_at, :naive_datetime)
    end
  end
end
