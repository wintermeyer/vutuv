defmodule Vutuv.Repo.Migrations.CreateTrappedRegistrations do
  @moduledoc """
  Sign-ups that `Vutuv.SignupTrap` caught: a scripted registration gets the
  ordinary PIN screen, but no account and no mail, and what it submitted lands
  here for the operator's weekly report. Rows are deleted 14 days after they
  arrive, so the table only ever holds the last two weeks.

  The columns copy their siblings' types: `first_name`, `last_name` and `email`
  are varchar(255) like `users` and `emails`, and the changeset that trapped
  them already validated them against those limits. `tag_list`, `user_agent`
  and `accept_language` are free text a client chooses, so they are `text`
  and capped in code. A plain new table, safe for the release still serving
  during the deploy.
  """

  use Ecto.Migration

  def change do
    create table(:trapped_registrations) do
      add(:rule, :string, null: false)
      add(:first_name, :string)
      add(:last_name, :string)
      add(:email, :string)
      add(:tag_list, :text)
      add(:params, :map, null: false, default: %{})
      add(:ip_address, :string)
      add(:user_agent, :text)
      add(:accept_language, :text)
      add(:reported_at, :utc_datetime)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create(index(:trapped_registrations, [:inserted_at]))
  end
end
