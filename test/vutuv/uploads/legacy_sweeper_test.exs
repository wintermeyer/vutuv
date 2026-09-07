defmodule Vutuv.Uploads.LegacySweeperTest do
  @moduledoc """
  The contract step of the avatar/cover fingerprint migration: once a row is on
  the fingerprinted scheme, delete the legacy files the regenerator kept during
  expand. It must be safe — never touch a row still on the legacy scheme, and
  never strip the legacy files out from under a half-migrated row.
  """
  # Not async: sets the global `:uploads_dir_prefix` application env.
  use Vutuv.DataCase, async: false

  import Vutuv.Factory
  # Since #2027 a picture IS its row in the shared `images` table: this sweeper
  # picks its rows by the member row's pointer at one and reads the fingerprint
  # off the row, so a fixture that sets only `users.avatar` is a member with no
  # picture at all.
  import Vutuv.ImageHelpers

  alias Vutuv.Uploads.LegacySweeper
  alias Vutuv.Uploads.Spec

  # A row only counts as migrated once EVERY current version is on disk, so the
  # fixture writes them from the spec rather than naming two of them: adding a
  # version (the avatar's `:large`) would otherwise leave this fixture
  # half-migrated and every assertion here reading "skipped".
  @avatar_versions Enum.map(Spec.versions(:avatar), & &1.name)

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_sweep_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev = Application.get_env(:vutuv, :uploads_dir_prefix)
    Application.put_env(:vutuv, :uploads_dir_prefix, tmp)

    on_exit(fn ->
      File.rm_rf(tmp)

      if prev,
        do: Application.put_env(:vutuv, :uploads_dir_prefix, prev),
        else: Application.delete_env(:vutuv, :uploads_dir_prefix)
    end)

    {:ok, tmp: tmp}
  end

  defp touch!(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "x")
    path
  end

  # A migrated avatar: fingerprint persisted, and on disk both the current
  # fingerprinted versions and the kept legacy derived files.
  defp migrated_avatar!(tmp, fp \\ "abc123abc123") do
    user = insert(:user, first_name: "Ada", last_name: "King", avatar: "selfie.jpg")
    {:ok, user} = user |> Ecto.Changeset.change(avatar_fingerprint: fp) |> Repo.update()
    user = with_image_rows(user)
    dir = Path.join(tmp, "avatars/#{user.id}")

    for version <- @avatar_versions do
      touch!(Path.join(dir, "#{user.username}-#{version}-#{fp}.avif"))
    end

    touch!(Path.join(dir, "Ada King_thumb.jpg"))
    touch!(Path.join(dir, "Ada King_medium.jpg"))
    {user, dir, fp}
  end

  test "removes legacy files, keeps the current fingerprinted versions", %{tmp: tmp} do
    {user, dir, fp} = migrated_avatar!(tmp)

    assert %{avatars: %{rows: 1, files_removed: 2, skipped: 0}} =
             LegacySweeper.run(only: :avatars)

    assert Enum.sort(File.ls!(dir)) ==
             Enum.sort(for v <- @avatar_versions, do: "#{user.username}-#{v}-#{fp}.avif")
  end

  test "dry run reports without deleting", %{tmp: tmp} do
    {_user, dir, _fp} = migrated_avatar!(tmp)

    assert %{avatars: %{rows: 1, files_removed: 2, skipped: 0}} =
             LegacySweeper.run(only: :avatars, dry_run: true)

    assert length(File.ls!(dir)) == length(@avatar_versions) + 2
  end

  # Since #2027 the query picks every member with a picture and the fingerprint
  # is read off its row, so a legacy-scheme picture is loaded and then refused
  # inside `Vutuv.Uploads.sweep_legacy/3` — it counts as skipped rather than
  # being filtered out before the sweeper ever sees it. What must not move is
  # the file: nothing is removed, either way.
  test "never strips a row still on the legacy scheme (nil fingerprint)", %{tmp: tmp} do
    user =
      with_image_rows(insert(:user, first_name: "Ada", last_name: "King", avatar: "selfie.jpg"))

    dir = Path.join(tmp, "avatars/#{user.id}")
    touch!(Path.join(dir, "Ada King_thumb.jpg"))

    assert %{avatars: %{rows: 0, files_removed: 0, skipped: 1}} =
             LegacySweeper.run(only: :avatars)

    assert File.exists?(Path.join(dir, "Ada King_thumb.jpg"))
  end

  test "leaves a half-migrated row (current versions missing) untouched", %{tmp: tmp} do
    fp = "abc123abc123"
    user = insert(:user, first_name: "Ada", last_name: "King", avatar: "selfie.jpg")
    {:ok, user} = user |> Ecto.Changeset.change(avatar_fingerprint: fp) |> Repo.update()
    _user = with_image_rows(user)
    dir = Path.join(tmp, "avatars/#{user.id}")
    # Only the legacy file exists; the current fingerprinted versions are absent,
    # so stripping the legacy file would leave the row with nothing.
    touch!(Path.join(dir, "Ada King_thumb.jpg"))

    assert %{avatars: %{rows: 0, files_removed: 0, skipped: 1}} =
             LegacySweeper.run(only: :avatars)

    assert File.exists?(Path.join(dir, "Ada King_thumb.jpg"))
  end
end
