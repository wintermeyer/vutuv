defmodule Vutuv.Repo.Migrations.CreatePeopleSnapshots do
  @moduledoc """
  One row per German calendar day holding the two head counts the investor page
  (`/system/investors`) draws as a growth curve: the members of this
  installation and the Fediverse accounts following something on it. Live, the
  same pair is what `Vutuv.PeopleCounter` publishes into the top bar; this table
  is its history, written once a day by `Vutuv.PeopleHistory.Recorder`.

  A curve needs a past, and this table has none on the day it is created, so the
  migration backfills the previous 30 days. That backfill is a **reconstruction
  from the rows that exist right now**, not a measurement, and it is biased
  downwards in three known ways: a member who has since deleted their account is
  missing from every day they were actually there, a Fediverse follower pruned
  as unreachable likewise, and `email_confirmed?` is read as it stands today, so
  a sign-up that confirmed late counts from the day it registered. Nothing in
  the table marks those days apart (a deliberate call): they are the same
  quantity, counted as well as it can still be counted. Every day from the first
  recorder run on is exact.
  """

  use Ecto.Migration

  alias Vutuv.Fediverse
  alias Vutuv.UUIDv7

  # How many days back the reconstruction reaches.
  @backfill_days 30

  def up do
    create table(:people_snapshots) do
      add(:day, :date, null: false)
      add(:members, :integer, null: false)
      add(:fediverse_accounts, :integer, null: false)

      timestamps()
    end

    create(unique_index(:people_snapshots, [:day]))

    flush()

    backfill()
  end

  def down do
    drop(table(:people_snapshots))
  end

  # One query for all 30 days: `generate_series` walks the Berlin calendar days
  # and each row carries the two counts as of that day's end. The boundary is
  # built as Berlin-local midnight and converted back to a naive UTC timestamp,
  # because that is what `inserted_at` holds.
  defp backfill do
    # From config, not `VutuvWeb.Endpoint.host/0`: a migration runs before the
    # endpoint is started, and asking it there raises.
    hosts =
      :vutuv
      |> Application.get_env(VutuvWeb.Endpoint, [])
      |> get_in([:url, :host])
      |> Kernel.||("localhost")
      |> Fediverse.own_hosts()

    %{rows: rows} =
      repo().query!(
        """
        SELECT d::date AS day,
               (SELECT count(*)
                  FROM users u
                 WHERE (u."email_confirmed?" IS NULL OR u."email_confirmed?")
                   AND u.inserted_at < ((d + interval '1 day') AT TIME ZONE 'Europe/Berlin') AT TIME ZONE 'UTC'
               ) AS members,
               (SELECT count(DISTINCT f.actor_uri)
                  FROM fediverse_followers f
                 WHERE coalesce(lower(substring(f.actor_uri from '^[a-z]+://([^/:#]+)')), '') <> ALL($3)
                   AND f.inserted_at < ((d + interval '1 day') AT TIME ZONE 'Europe/Berlin') AT TIME ZONE 'UTC'
               ) AS fediverse_accounts
          FROM generate_series($1::date, $2::date, interval '1 day') AS d
        """,
        [Date.add(Date.utc_today(), -@backfill_days), Date.add(Date.utc_today(), -1), hosts]
      )

    now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

    entries =
      Enum.map(rows, fn [day, members, fediverse_accounts] ->
        %{
          # A raw table name carries no field types, so the id is dumped to the
          # 16 bytes the uuid column wants rather than handed over as text.
          id: Ecto.UUID.dump!(UUIDv7.generate()),
          day: day,
          members: members,
          fediverse_accounts: fediverse_accounts,
          inserted_at: now,
          updated_at: now
        }
      end)

    repo().insert_all("people_snapshots", entries)
  end
end
