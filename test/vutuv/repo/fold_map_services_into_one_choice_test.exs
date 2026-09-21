defmodule Vutuv.Repo.FoldMapServicesIntoOneChoiceTest do
  @moduledoc """
  Covers the one-time migration `fold_map_services_into_one_choice`, which
  turns the three per-service map switches plus a default into the one
  `default_map_service` value (with `"none"`), for every member and for the
  installation default, so nobody's address links change on the deploy.

  It drives `choice/2` and `fold/1`, the migration's own code, so the two
  cannot drift apart. The switches are no longer schema fields, so the rows
  are shaped with plain SQL, the way the migration reads them.

  `async: false`: the module is loaded from `priv/repo/migrations` with
  `Code.require_file/1`, which is global, and the installation default is one
  shared row.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Accounts.User
  alias Vutuv.Prefs
  alias Vutuv.Prefs.Default

  @migration Vutuv.Repo.Migrations.FoldMapServicesIntoOneChoice

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      [file] = Path.wildcard("priv/repo/migrations/*_fold_map_services_into_one_choice.exs")
      Code.require_file(file)
    end

    :ok
  end

  defp member(google, osm, apple, default) do
    user = insert(:user)

    Repo.query!(
      ~s(UPDATE users SET "map_google?" = $1, "map_openstreetmap?" = $2, "map_apple?" = $3,
         default_map_service = $4 WHERE id = $5::text::uuid),
      [google, osm, apple, default, user.id]
    )

    user
  end

  defp installation(rows) do
    for {key, value} <- rows do
      Repo.insert!(%Default{key: key, value: value})
    end
  end

  defp stored(user), do: Repo.get!(User, user.id).default_map_service

  describe "choice/2" do
    test "keeps the default while it is switched on" do
      assert @migration.choice(
               %{"google" => true, "openstreetmap" => true, "apple" => true},
               "apple"
             ) ==
               "apple"
    end

    test "falls back to the first service still on, in the old display order" do
      assert @migration.choice(
               %{"google" => false, "openstreetmap" => true, "apple" => true},
               "google"
             ) ==
               "openstreetmap"
    end

    test "is \"none\" when every service is off" do
      assert @migration.choice(
               %{"google" => false, "openstreetmap" => false, "apple" => false},
               "apple"
             ) ==
               "none"
    end
  end

  describe "fold/1 for members" do
    test "gives every member the link they saw before, and leaves the rest inheriting" do
      picked_osm = member(nil, nil, nil, "openstreetmap")
      all_off = member(false, false, false, "apple")
      google_off = member(false, nil, nil, nil)
      apple_off = member(nil, nil, false, nil)
      untouched = member(nil, nil, nil, nil)

      @migration.fold(Repo)

      assert stored(picked_osm) == "openstreetmap"
      assert stored(all_off) == "none"
      # Google was the inherited default and they switched it off, so they
      # saw OpenStreetMap, the first service left on.
      assert stored(google_off) == "openstreetmap"
      # Switching off a service that was never shown changed nothing for
      # them, so they keep inheriting.
      assert stored(apple_off) == nil
      assert stored(untouched) == nil
    end
  end

  describe "fold/1 for the installation default" do
    test "turns switched-off services into the one default the untouched members saw" do
      installation(%{"map_google?" => "false"})
      untouched = member(nil, nil, nil, nil)

      @migration.fold(Repo)

      assert Prefs.list_default_rows()[:default_map_service] == "openstreetmap"
      assert Prefs.load_installation_defaults()[:default_map_service] == "openstreetmap"
      # Still inheriting, and the inherited answer did not change.
      assert stored(untouched) == nil
    end

    test "every service off becomes \"none\"" do
      installation(%{
        "map_google?" => "false",
        "map_openstreetmap?" => "false",
        "map_apple?" => "false"
      })

      @migration.fold(Repo)

      assert Prefs.list_default_rows()[:default_map_service] == "none"
    end

    test "a member measured against a changed installation default" do
      installation(%{"map_google?" => "false"})
      # Switched Google back on for themselves, so they kept seeing Google
      # while everybody else got OpenStreetMap.
      back_on = member(true, nil, nil, nil)

      @migration.fold(Repo)

      assert stored(back_on) == "google"
    end

    test "writes no row while the installation keeps the shipped Google default" do
      @migration.fold(Repo)

      assert Prefs.list_default_rows()[:default_map_service] == nil
    end
  end
end
