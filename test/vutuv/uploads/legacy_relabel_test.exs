defmodule Vutuv.Uploads.LegacyRelabelTest do
  @moduledoc """
  The cutover step that keeps image files reachable across the integer -> UUID
  id conversion: the on-disk image trees are named for the DB id
  (`avatars/<user.id>`, `covers/<user.id>`, `screenshots/<url.id>` and their
  `originals/` mirrors), so when `users.id`/`urls.id` change type the
  directories must be renamed from the old integer to the new UUID. The map
  comes from the `legacy_id_map` table the conversion migration leaves behind;
  `relabel/2` does the renaming and must be idempotent, never overwrite, and
  leave dirs no row claims alone.
  """
  # Not async: sets the global `:uploads_dir_prefix` application env.
  use Vutuv.DataCase, async: false

  alias Vutuv.Repo
  alias Vutuv.Uploads.LegacyRelabel

  @uuid_user "01588143-47e0-7e2d-b883-be4f815cc789"
  @uuid_user2 "0190aaaa-bbbb-7ccc-8ddd-eeeeeeeeeeee"
  @uuid_url "0188dddd-eeee-7fff-8000-111111111111"

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_relabel_#{System.unique_integer([:positive])}")
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

  # A directory under `tmp` holding one file, so a rename has something to move.
  defp dir!(tmp, rel, file) do
    dir = Path.join(tmp, rel)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, file), "x")
    dir
  end

  describe "relabel/2" do
    test "renames the id-keyed dirs (and their originals) from integer to UUID", %{tmp: tmp} do
      dir!(tmp, "avatars/1", "Ada King_medium.avif")
      dir!(tmp, "covers/1", "Ada King_wide.avif")
      dir!(tmp, "originals/avatars/1", "original.jpg")
      dir!(tmp, "originals/covers/1", "original.jpg")
      dir!(tmp, "screenshots/7", "thumb-abc.avif")
      dir!(tmp, "originals/screenshots/7", "original.png")

      mapping = [{"users", 1, @uuid_user}, {"urls", 7, @uuid_url}]

      # avatars/1, covers/1, originals/avatars/1, originals/covers/1,
      # screenshots/7, originals/screenshots/7 = 6 directories.
      assert LegacyRelabel.relabel(mapping).renamed == 6

      # New UUID homes hold the files; the integer dirs are gone.
      assert File.exists?(Path.join(tmp, "avatars/#{@uuid_user}/Ada King_medium.avif"))
      assert File.exists?(Path.join(tmp, "covers/#{@uuid_user}/Ada King_wide.avif"))
      assert File.exists?(Path.join(tmp, "originals/avatars/#{@uuid_user}/original.jpg"))
      assert File.exists?(Path.join(tmp, "originals/covers/#{@uuid_user}/original.jpg"))
      assert File.exists?(Path.join(tmp, "screenshots/#{@uuid_url}/thumb-abc.avif"))
      assert File.exists?(Path.join(tmp, "originals/screenshots/#{@uuid_url}/original.png"))

      refute File.exists?(Path.join(tmp, "avatars/1"))
      refute File.exists?(Path.join(tmp, "screenshots/7"))
      refute File.exists?(Path.join(tmp, "originals/avatars/1"))
    end

    test "is idempotent: a second run renames nothing and keeps the UUID dirs", %{tmp: tmp} do
      dir!(tmp, "avatars/1", "Ada King_medium.avif")
      mapping = [{"users", 1, @uuid_user}]

      assert LegacyRelabel.relabel(mapping).renamed == 1

      summary = LegacyRelabel.relabel(mapping)
      assert summary.renamed == 0
      assert summary.already_uuid == 1
      assert File.exists?(Path.join(tmp, "avatars/#{@uuid_user}/Ada King_medium.avif"))
    end

    test "leaves a dir no mapping row claims untouched (deleted/renamed row)", %{tmp: tmp} do
      dir!(tmp, "avatars/999", "Gone User_medium.avif")
      mapping = [{"users", 1, @uuid_user}]

      summary = LegacyRelabel.relabel(mapping)

      assert summary.renamed == 0
      assert summary.unmapped == 1
      assert File.exists?(Path.join(tmp, "avatars/999/Gone User_medium.avif"))
    end

    test "dry run reports the count without moving anything", %{tmp: tmp} do
      dir!(tmp, "avatars/1", "Ada King_medium.avif")
      mapping = [{"users", 1, @uuid_user}]

      summary = LegacyRelabel.relabel(mapping, dry_run: true)

      assert summary.renamed == 1
      assert File.exists?(Path.join(tmp, "avatars/1/Ada King_medium.avif"))
      refute File.exists?(Path.join(tmp, "avatars/#{@uuid_user}"))
    end

    test "never overwrites: an existing UUID target is left in place, counted", %{tmp: tmp} do
      dir!(tmp, "avatars/1", "Ada King_medium.avif")
      dir!(tmp, "avatars/#{@uuid_user}", "Existing_medium.avif")
      mapping = [{"users", 1, @uuid_user}]

      summary = LegacyRelabel.relabel(mapping)

      assert summary.renamed == 0
      assert summary.conflict == 1
      # Both the source and the pre-existing target survive untouched.
      assert File.exists?(Path.join(tmp, "avatars/1/Ada King_medium.avif"))
      assert File.exists?(Path.join(tmp, "avatars/#{@uuid_user}/Existing_medium.avif"))
    end

    test "distinct legacy ids map to their own UUIDs", %{tmp: tmp} do
      dir!(tmp, "avatars/1", "Ada King_medium.avif")
      dir!(tmp, "avatars/2", "Bob Roy_medium.avif")
      mapping = [{"users", 1, @uuid_user}, {"users", 2, @uuid_user2}]

      assert LegacyRelabel.relabel(mapping).renamed == 2
      assert File.exists?(Path.join(tmp, "avatars/#{@uuid_user}/Ada King_medium.avif"))
      assert File.exists?(Path.join(tmp, "avatars/#{@uuid_user2}/Bob Roy_medium.avif"))
    end
  end

  describe "run/1 (reads the legacy_id_map table)" do
    # CREATE ... IF NOT EXISTS so the test passes whether or not the conversion
    # migration (which creates the table for real) has run in this DB; the
    # sandbox transaction rolls it back either way.
    defp ensure_map_table! do
      Repo.query!("""
      CREATE TABLE IF NOT EXISTS legacy_id_map (
        entity text NOT NULL,
        legacy_id bigint NOT NULL,
        uuid uuid NOT NULL,
        PRIMARY KEY (entity, legacy_id)
      )
      """)
    end

    test "renames using the rows in the table (verifies uuid formatting)", %{tmp: tmp} do
      ensure_map_table!()

      # Postgrex wants a 16-byte binary for a uuid column; dump the canonical
      # string (a test-only encode, not id generation).
      Repo.query!(
        "INSERT INTO legacy_id_map (entity, legacy_id, uuid) VALUES ('users', 1, $1)",
        [Ecto.UUID.dump!(@uuid_user)]
      )

      dir!(tmp, "avatars/1", "Ada King_medium.avif")

      assert {:ok, summary} = LegacyRelabel.run()
      assert summary.renamed == 1
      assert File.exists?(Path.join(tmp, "avatars/#{@uuid_user}/Ada King_medium.avif"))
    end

    test "returns {:error, :no_mapping} when the table holds no rows" do
      ensure_map_table!()
      Repo.query!("DELETE FROM legacy_id_map")
      assert LegacyRelabel.run() == {:error, :no_mapping}
    end
  end
end
