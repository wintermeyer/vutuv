defmodule Vutuv.Repo.Migrations.FoldMapServicesIntoOneChoice do
  @moduledoc """
  Folds the three per-service map switches (`map_google?`,
  `map_openstreetmap?`, `map_apple?`) and `default_map_service` into the one
  value `default_map_service`, which may now also be `"none"`.

  Since the profile address card became one link (PR #2262), the switches only
  decided which service that link used and whether there was one at all, so
  every stored combination collapses to one of four answers. This computes
  that answer the way `Vutuv.Maps` did before, for the installation default
  (`pref_defaults`) and for every member who had set anything, and stores it
  only where it differs from what the member would now inherit, so a member
  whose switches never changed their link keeps inheriting.

  Data only and N-1 safe: the previous release still reads the switches,
  which stay untouched, and treats an unknown `"none"` as "no preference",
  which for those members (every service off) already meant no link. The
  columns are dropped in a later deploy, which must also delete the
  `pref_defaults` rows for the three switch keys this leaves behind.
  """
  use Ecto.Migration

  import Ecto.Query

  # The old display order, which was also the fallback order.
  @services ~w(google openstreetmap apple)
  @shipped_default "google"

  def up, do: fold(repo())

  # The switches are left in place, so going back only has to undo "none",
  # which the previous release knows as every switch off.
  def down do
    execute("""
    UPDATE users SET "map_google?" = false, "map_openstreetmap?" = false,
      "map_apple?" = false, default_map_service = NULL
    WHERE default_map_service = 'none'
    """)

    execute("DELETE FROM pref_defaults WHERE key = 'default_map_service' AND value = 'none'")
  end

  @doc "Folds every stored map setting, the installation default first."
  def fold(repo) do
    installation = installation(repo)
    inherited = choice(installation.flags, installation.default)

    put_installation_default(repo, inherited)
    fold_members(repo, installation, inherited)
  end

  @doc """
  The one answer a set of switches and a default gave: the default while it is
  switched on, else the first service still on, else `"none"`.
  """
  def choice(flags, default) do
    case Enum.filter(@services, &Map.fetch!(flags, &1)) do
      [] -> "none"
      enabled -> if default in enabled, do: default, else: hd(enabled)
    end
  end

  defp installation(repo) do
    rows =
      from(d in "pref_defaults", select: {d.key, d.value})
      |> repo.all()
      |> Map.new()

    %{
      flags: Map.new(@services, &{&1, rows["map_#{&1}?"] != "false"}),
      default: rows["default_map_service"] || @shipped_default
    }
  end

  defp put_installation_default(repo, @shipped_default) do
    repo.query!("DELETE FROM pref_defaults WHERE key = 'default_map_service'")
  end

  defp put_installation_default(repo, choice) do
    repo.query!(
      """
      INSERT INTO pref_defaults (id, key, value, inserted_at, updated_at)
      VALUES ($1::text::uuid, 'default_map_service', $2, now()::timestamp(0), now()::timestamp(0))
      ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at
      """,
      [Vutuv.UUIDv7.generate(), choice]
    )
  end

  # An unset switch reads the installation's, so every row arrives as three
  # plain booleans.
  defp fold_members(repo, installation, inherited) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT id, COALESCE("map_google?", $1), COALESCE("map_openstreetmap?", $2),
          COALESCE("map_apple?", $3), default_map_service
        FROM users
        WHERE "map_google?" IS NOT NULL OR "map_openstreetmap?" IS NOT NULL
          OR "map_apple?" IS NOT NULL OR default_map_service IS NOT NULL
        """,
        Enum.map(@services, &installation.flags[&1])
      )

    rows
    |> Enum.flat_map(&member_change(&1, installation.default, inherited))
    |> Enum.group_by(fn {_id, value} -> value end, fn {id, _value} -> id end)
    |> Enum.each(fn {value, ids} ->
      repo.query!("UPDATE users SET default_map_service = $1 WHERE id = ANY($2)", [value, ids])
    end)
  end

  # A member keeps an own value when they had picked a default themselves or
  # when their switches gave them a different link than inheriting would.
  defp member_change([id, google, osm, apple, own_default], installation_default, inherited) do
    flags = %{"google" => google, "openstreetmap" => osm, "apple" => apple}
    value = choice(flags, own_default || installation_default)

    if value != own_default and (own_default != nil or value != inherited),
      do: [{id, value}],
      else: []
  end
end
