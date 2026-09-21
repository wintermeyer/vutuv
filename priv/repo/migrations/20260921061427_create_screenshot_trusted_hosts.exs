defmodule Vutuv.Repo.Migrations.CreateScreenshotTrustedHosts do
  @moduledoc """
  The sites whose link screenshots skip the AI image scan
  (`Vutuv.ScreenshotTrust`), edited at /admin/screenshots?tab=trusted.

  Starts empty on every installation, vutuv.de included: trusting a site is a
  decision an admin makes about their own installation, so nothing is seeded.
  A plain new table, safe for the release still serving during the deploy.
  """

  use Ecto.Migration

  def change do
    create table(:screenshot_trusted_hosts) do
      add(:host, :string, null: false)
      add(:note, :string)

      timestamps()
    end

    create(unique_index(:screenshot_trusted_hosts, [:host]))
  end
end
