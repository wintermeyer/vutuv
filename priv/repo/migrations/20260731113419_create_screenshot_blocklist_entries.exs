defmodule Vutuv.Repo.Migrations.CreateScreenshotBlocklistEntries do
  @moduledoc """
  The screenshot blocklist becomes per-installation **data** with an admin UI
  (/admin/screenshots?tab=blocklist) instead of a config list only a source or
  `.env` edit could change.

  The table is seeded with the two sites we know answer a capture with a
  consent wall, **plus** whatever the installation has configured right now
  (`:screenshot_blocklist`, i.e. an operator's own `SCREENSHOT_BLOCKLIST` /
  `SCREENSHOT_BLOCKED_HOSTS`). Both halves matter: an operator's list must not
  be silently dropped on the way in (an entry that quietly stopped applying
  would send Chromium back to the very pages it was told to leave alone), and
  an installation that had *replaced* the default list still gets the two
  shipped entries, which is what "add heise.de to the blocklist" means. Either
  is one click away from removal at /admin/screenshots?tab=blocklist.
  """

  use Ecto.Migration

  # A snapshot on purpose: a migration records what was true when it ran, so it
  # must not follow a later edit of the config default.
  @shipped ["reddit.com", "heise.de"]

  def up do
    create table(:screenshot_blocklist_entries) do
      add(:pattern, :string, null: false)
      add(:note, :string)

      timestamps()
    end

    create(unique_index(:screenshot_blocklist_entries, [:pattern]))

    flush()

    seed()
  end

  def down do
    drop(table(:screenshot_blocklist_entries))
  end

  defp seed do
    now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

    rows =
      (@shipped ++ Application.get_env(:vutuv, :screenshot_blocklist, []))
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.map(
        &%{
          # A raw table name carries no field types, so the id is dumped to the
          # 16 bytes the uuid column wants rather than handed over as text.
          id: Ecto.UUID.dump!(Vutuv.UUIDv7.generate()),
          pattern: &1,
          note: nil,
          inserted_at: now,
          updated_at: now
        }
      )

    Vutuv.Repo.insert_all("screenshot_blocklist_entries", rows, on_conflict: :nothing)
  end
end
