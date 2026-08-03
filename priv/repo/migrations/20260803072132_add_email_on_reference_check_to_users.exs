defmodule Vutuv.Repo.Migrations.AddEmailOnReferenceCheckToUsers do
  @moduledoc """
  Whether a member is emailed once the AI review of their Arbeitszeugnis is
  finished.

  Default **true**, unlike every other notification-email switch here, which is
  opt-in. Those announce something somebody else did. This one answers a
  question the member asked and then waited minutes for, possibly behind a
  queue — and the whole point of it is that they may close the tab and get on
  with their day. Defaulting it off would take that promise back.
  """

  use Ecto.Migration

  def change do
    alter table(:users) do
      add(:email_on_reference_check?, :boolean, default: true, null: false)
    end
  end
end
