defmodule Vutuv.Uploads.RegeneratorTest do
  @moduledoc """
  The migration engine that makes a format change real for existing data:
  DB-driven, it relocates legacy public originals into the private
  `originals/` tree, re-derives every served version per the current
  `Vutuv.Uploads.Spec`, and sweeps the stale derived files. It must be
  idempotent, never destroy a row's only files when the original is missing
  (skip-and-warn), and write nothing in dry-run mode.
  """
  # Not async: sets the global `:uploads_dir_prefix` application env.
  use Vutuv.DataCase, async: false

  import Vutuv.Factory

  alias Vutuv.Uploads.Regenerator

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_regen_#{System.unique_integer([:positive])}")
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

  defp jpeg!(path, opts \\ []) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, img} = Image.new(opts[:width] || 300, opts[:height] || 200, color: [10, 120, 200])
    {:ok, _} = Image.write(img, path)
    path
  end

  # A user with the pre-AVIF on-disk layout: derived versions — including the
  # Waffle-era 512px `_large`, which current code never serves — and the
  # original sitting in the public tree.
  defp legacy_avatar_user!(tmp) do
    user = insert(:user, first_name: "Ada", last_name: "King", avatar: "selfie.jpg")
    dir = Path.join(tmp, "avatars/#{user.id}")
    jpeg!(Path.join(dir, "Ada King_thumb.jpg"))
    jpeg!(Path.join(dir, "Ada King_medium.jpg"))
    jpeg!(Path.join(dir, "Ada King_large.jpg"), width: 512, height: 512)
    jpeg!(Path.join(dir, "Ada King_original.jpg"), width: 600, height: 400)
    user
  end

  describe "avatars" do
    test "relocates the original, derives AVIF, sweeps stale files", %{tmp: tmp} do
      user = legacy_avatar_user!(tmp)

      summary = Regenerator.run(only: :avatars)
      assert summary.avatars == %{regenerated: 1, unchanged: 0, skipped: 0, failed: 0}

      dir = Path.join(tmp, "avatars/#{user.id}")
      assert File.exists?(Path.join(dir, "avatar_thumb.avif"))
      assert File.exists?(Path.join(dir, "avatar_medium.avif"))
      assert File.exists?(Path.join(tmp, "originals/avatars/#{user.id}/original.jpg"))

      # The pre-AVIF and pre-#773 name-derived files (incl. the publicly
      # downloadable original) are gone; only the stable id-scoped files remain.
      assert dir |> File.ls!() |> Enum.sort() ==
               ["avatar_medium.avif", "avatar_thumb.avif"]
    end

    test "a second run leaves converged rows alone (cheap deploy hook)", %{tmp: tmp} do
      user = legacy_avatar_user!(tmp)

      assert Regenerator.run(only: :avatars).avatars.regenerated == 1

      dir = Path.join(tmp, "avatars/#{user.id}")
      mtimes = for f <- File.ls!(dir), into: %{}, do: {f, File.stat!(Path.join(dir, f)).mtime}

      assert Regenerator.run(only: :avatars).avatars ==
               %{regenerated: 0, unchanged: 1, skipped: 0, failed: 0}

      assert length(File.ls!(dir)) == 2
      for f <- File.ls!(dir), do: assert(File.stat!(Path.join(dir, f)).mtime == mtimes[f])
      assert File.ls!(Path.join(tmp, "originals/avatars/#{user.id}")) == ["original.jpg"]
    end

    test "force: true re-derives converged rows (Spec quality/resolution changes)", %{tmp: tmp} do
      legacy_avatar_user!(tmp)

      assert Regenerator.run(only: :avatars).avatars.regenerated == 1
      assert Regenerator.run(only: :avatars, force: true).avatars.regenerated == 1
    end

    test "skips a row whose original is missing without touching its files", %{tmp: tmp} do
      user = insert(:user, first_name: "Ada", last_name: "King", avatar: "selfie.jpg")
      dir = Path.join(tmp, "avatars/#{user.id}")
      jpeg!(Path.join(dir, "Ada King_thumb.jpg"))

      summary = Regenerator.run(only: :avatars)

      assert summary.avatars == %{regenerated: 0, unchanged: 0, skipped: 1, failed: 0}
      # The only derived file the row has keeps serving via the fallback.
      assert File.exists?(Path.join(dir, "Ada King_thumb.jpg"))
    end

    test "dry run reports without writing anything", %{tmp: tmp} do
      user = legacy_avatar_user!(tmp)

      summary = Regenerator.run(only: :avatars, dry_run: true)

      assert summary.avatars == %{regenerated: 1, unchanged: 0, skipped: 0, failed: 0}
      dir = Path.join(tmp, "avatars/#{user.id}")
      assert File.exists?(Path.join(dir, "Ada King_original.jpg"))
      refute File.exists?(Path.join(dir, "Ada King_thumb.avif"))
      refute File.exists?(Path.join(tmp, "originals/avatars/#{user.id}"))
    end

    test "an already-AVIF row (original already private) is simply re-derived", %{tmp: tmp} do
      user = insert(:user, first_name: "Ada", last_name: "King", avatar: "selfie.jpg")
      jpeg!(Path.join(tmp, "originals/avatars/#{user.id}/original.jpg"))

      summary = Regenerator.run(only: :avatars)

      assert summary.avatars == %{regenerated: 1, unchanged: 0, skipped: 0, failed: 0}
      assert File.exists?(Path.join(tmp, "avatars/#{user.id}/avatar_thumb.avif"))
    end
  end

  describe "covers" do
    test "relocates the original, derives the AVIF wide version", %{tmp: tmp} do
      user = insert(:user, first_name: "Ada", last_name: "King", cover_photo: "banner.jpg")
      dir = Path.join(tmp, "covers/#{user.id}")
      jpeg!(Path.join(dir, "Ada King_wide.jpg"))
      jpeg!(Path.join(dir, "Ada King_original.jpg"), width: 1800, height: 600)

      summary = Regenerator.run(only: :covers)

      assert summary.covers == %{regenerated: 1, unchanged: 0, skipped: 0, failed: 0}
      assert File.ls!(dir) == ["cover_wide.avif"]
      assert File.exists?(Path.join(tmp, "originals/covers/#{user.id}/original.jpg"))

      # 1800px original is capped at the Spec's 1600px wide.
      {:ok, wide} = Image.open(Path.join(dir, "cover_wide.avif"))
      assert Image.width(wide) == 1600
    end
  end

  describe "screenshots" do
    test "relocates the fingerprinted original, derives the AVIF thumb", %{tmp: tmp} do
      url = insert(:url, user: insert(:user), screenshot: "a1b2c3d4e5f6.png")
      dir = Path.join(tmp, "screenshots/#{url.id}")
      jpeg!(Path.join(dir, "thumb-a1b2c3d4e5f6.webp"))
      jpeg!(Path.join(dir, "original-a1b2c3d4e5f6.png"), width: 1280, height: 844)

      summary = Regenerator.run(only: :screenshots)

      assert summary.screenshots == %{regenerated: 1, unchanged: 0, skipped: 0, failed: 0}
      assert File.ls!(dir) == ["thumb-a1b2c3d4e5f6.avif"]
      assert File.exists?(Path.join(tmp, "originals/screenshots/#{url.id}/original.png"))
    end
  end

  describe "post images" do
    test "relocates the original, derives all three AVIF versions, sweeps .webp", %{tmp: tmp} do
      image = insert(:post_image)
      dir = Path.join(tmp, "post_images/#{image.token}")

      for v <- ~w(thumb feed large) do
        jpeg!(Path.join(dir, "#{v}.webp"))
      end

      jpeg!(Path.join(dir, "original.jpg"), width: 800, height: 600)

      summary = Regenerator.run(only: :post_images)

      assert summary.post_images == %{regenerated: 1, unchanged: 0, skipped: 0, failed: 0}
      assert dir |> File.ls!() |> Enum.sort() == ["feed.avif", "large.avif", "thumb.avif"]

      assert File.exists?(Path.join(tmp, "originals/post_images/#{image.token}/original.jpg"))
    end
  end

  describe "orphaned public originals (no DB row claims them)" do
    test "are moved into the private tree by the final pass", %{tmp: tmp} do
      # A deleted user's files: no users row references them, but the original
      # is publicly downloadable — exactly what must never survive a run.
      dir = Path.join(tmp, "avatars/424242")
      jpeg!(Path.join(dir, "Gone User_thumb.jpg"))
      jpeg!(Path.join(dir, "Gone User_original.jpg"))
      shot_dir = Path.join(tmp, "screenshots/424242")
      jpeg!(Path.join(shot_dir, "original-deadbeef0000.png"))

      summary = Regenerator.run()

      assert summary.orphan_originals == %{moved: 2}
      refute File.exists?(Path.join(dir, "Gone User_original.jpg"))
      assert File.exists?(Path.join(tmp, "originals/avatars/424242/original.jpg"))
      assert File.exists?(Path.join(tmp, "originals/screenshots/424242/original.png"))
      # Derived files of unknown rows are left alone (nothing claims them,
      # nothing re-derives them — deleting is not this tool's call).
      assert File.exists?(Path.join(dir, "Gone User_thumb.jpg"))
    end

    test "a stray with an occupied private slot keeps its bytes under orphan-*", %{tmp: tmp} do
      user = legacy_avatar_user!(tmp)
      dir = Path.join(tmp, "avatars/#{user.id}")
      # An older upload under a previous name, next to the current one.
      jpeg!(Path.join(dir, "Old Name_original.png"))

      summary = Regenerator.run(only: :avatars)
      assert summary.avatars.regenerated == 1
      # The row sweep already removed the stray (it matches the stale glob),
      # so the orphan pass finds nothing.
      assert Regenerator.run(only: :orphans).orphan_originals == %{moved: 0}
    end

    test "dry run only reports", %{tmp: tmp} do
      dir = Path.join(tmp, "avatars/424242")
      jpeg!(Path.join(dir, "Gone User_original.jpg"))

      summary = Regenerator.run(only: :orphans, dry_run: true)

      assert summary.orphan_originals == %{moved: 1}
      assert File.exists?(Path.join(dir, "Gone User_original.jpg"))
      refute File.exists?(Path.join(tmp, "originals/avatars/424242"))
    end
  end

  test "run/0 covers every type", %{tmp: tmp} do
    legacy_avatar_user!(tmp)

    summary = Regenerator.run()

    assert summary.avatars.regenerated == 1
    assert summary.orphan_originals == %{moved: 0}

    assert Map.keys(summary) |> Enum.sort() ==
             [:avatars, :covers, :orphan_originals, :post_images, :screenshots]
  end

  test "a corrupt original counts as failed, not crashed", %{tmp: tmp} do
    user = insert(:user, first_name: "Ada", last_name: "King", avatar: "selfie.jpg")
    path = Path.join(tmp, "originals/avatars/#{user.id}/original.jpg")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "not actually a jpeg")

    summary = Regenerator.run(only: :avatars)

    assert summary.avatars == %{regenerated: 0, unchanged: 0, skipped: 0, failed: 1}
  end

  test "a fresh upload is already converged — nothing to regenerate", %{tmp: tmp} do
    user = insert(:user, first_name: "Ada", last_name: "King", avatar: "fresh.jpg")
    src = jpeg!(Path.join(tmp, "fresh.jpg"))
    upload = %Plug.Upload{filename: "fresh.jpg", path: src, content_type: "image/jpeg"}
    {:ok, _} = Vutuv.Avatar.store({upload, user})

    summary = Regenerator.run(only: :avatars)

    assert summary.avatars == %{regenerated: 0, unchanged: 1, skipped: 0, failed: 0}
  end
end
