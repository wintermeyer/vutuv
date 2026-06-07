defmodule Vutuv.ScreenshotTest do
  @moduledoc """
  Locks the on-disk and URL conventions for URL screenshots. The served thumb
  is AVIF (per `Vutuv.Uploads.Spec`) at `screenshots/<url.id>/thumb-<hash>.avif`
  (nginx `location /screenshots/`); the filename stays content-fingerprinted so
  it can be cached forever. The captured original is kept privately at
  `originals/screenshots/<url.id>/original<ext>` and is never served.
  """
  # Not async: these tests set the global `:uploads_dir_prefix` application env.
  use ExUnit.Case, async: false

  alias Vutuv.Profiles.Url

  @url %Url{id: 42}

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "vutuv_screenshot_test_#{System.unique_integer([:positive])}")

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

  describe "url/2" do
    test "thumb filename is fingerprinted from the stored hash, served as .avif" do
      assert Vutuv.Screenshot.url({"a1b2c3d4e5f6.webp", @url}, :thumb) ==
               "/screenshots/42/thumb-a1b2c3d4e5f6.avif"
    end

    test "the original is not URL-addressable" do
      assert Vutuv.Screenshot.url({"a1b2c3d4e5f6.jpg", @url}, :original) == nil
    end

    test "falls back to the local placeholder when there is no screenshot" do
      assert Vutuv.Screenshot.url({nil, @url}, :thumb) == "/images/screenshot.png"
    end

    test "tolerates a legacy '?<timestamp>' suffix in the stored value" do
      assert Vutuv.Screenshot.url({"shot.png?63876543210", @url}, :thumb) ==
               "/screenshots/42/thumb-shot.avif"
    end

    test "falls back to a not-yet-regenerated legacy .webp thumb", %{tmp: tmp} do
      dir = Path.join(tmp, "screenshots/42")
      File.mkdir_p!(dir)
      {:ok, img} = Image.new(20, 20, color: [1, 2, 3])
      {:ok, _} = Image.write(img, Path.join(dir, "thumb-a1b2c3d4e5f6.webp"))

      assert Vutuv.Screenshot.url({"a1b2c3d4e5f6.png", @url}, :thumb) ==
               "/screenshots/42/thumb-a1b2c3d4e5f6.webp"

      # Once the .avif exists it wins over the legacy file.
      {:ok, _} = Image.write(img, Path.join(dir, "thumb-a1b2c3d4e5f6.avif"))

      assert Vutuv.Screenshot.url({"a1b2c3d4e5f6.png", @url}, :thumb) ==
               "/screenshots/42/thumb-a1b2c3d4e5f6.avif"
    end
  end

  describe "store/1" do
    setup do
      {:ok, img} = Image.new(1280, 844, color: [200, 200, 200])
      src = Path.join(System.tmp_dir!(), "shot_#{System.unique_integer([:positive])}.png")
      {:ok, _} = Image.write(img, src)
      on_exit(fn -> File.rm(src) end)
      {:ok, src: src}
    end

    test "writes an 800x528 AVIF thumb publicly and the original privately", %{
      tmp: tmp,
      src: src
    } do
      upload = %Plug.Upload{filename: "shot.png", path: src, content_type: "image/png"}
      assert {:ok, stored} = Vutuv.Screenshot.store({upload, @url})
      assert stored =~ ~r/^[0-9a-f]{12}\.png$/

      hash = Path.rootname(stored)
      dir = Path.join(tmp, "screenshots/42")
      assert File.exists?(Path.join(dir, "thumb-#{hash}.avif"))
      assert File.exists?(Path.join(tmp, "originals/screenshots/42/original.png"))

      # Nothing original may land in the publicly served tree.
      assert dir |> File.ls!() |> Enum.filter(&String.contains?(&1, "original")) == []

      {:ok, thumb} = Image.open(Path.join(dir, "thumb-#{hash}.avif"))
      assert {Image.width(thumb), Image.height(thumb)} == {800, 528}
    end

    test "accepts whitelisted extensions regardless of case", %{src: src} do
      for filename <- ~w(shot.WEBP shot.PNG shot.JPG) do
        upload = %Plug.Upload{filename: filename, path: src, content_type: "image/png"}
        assert {:ok, _stored} = Vutuv.Screenshot.store({upload, @url})
      end
    end

    test "rejects files whose extension is not whitelisted", %{src: src} do
      upload = %Plug.Upload{filename: "shot.gif", path: src, content_type: "image/gif"}
      assert {:error, :invalid_file} = Vutuv.Screenshot.store({upload, @url})
    end

    test "regenerating with new content replaces the previous files", %{tmp: tmp, src: src} do
      up1 = %Plug.Upload{filename: "shot.png", path: src, content_type: "image/png"}
      assert {:ok, _first} = Vutuv.Screenshot.store({up1, @url})

      {:ok, img2} = Image.new(1280, 844, color: [10, 20, 30])
      src2 = Path.join(System.tmp_dir!(), "shot2_#{System.unique_integer([:positive])}.png")
      {:ok, _} = Image.write(img2, src2)
      on_exit(fn -> File.rm(src2) end)

      up2 = %Plug.Upload{filename: "shot.png", path: src2, content_type: "image/png"}
      assert {:ok, _second} = Vutuv.Screenshot.store({up2, @url})

      dir = Path.join(tmp, "screenshots/42")
      assert length(Path.wildcard(Path.join(dir, "thumb-*.avif"))) == 1
      assert length(Path.wildcard(Path.join(tmp, "originals/screenshots/42/original*"))) == 1
    end

    test "regeneration also sweeps legacy public files (webp thumbs, public originals)", %{
      tmp: tmp,
      src: src
    } do
      dir = Path.join(tmp, "screenshots/42")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "thumb-deadbeef0000.webp"), "legacy thumb")
      File.write!(Path.join(dir, "original-deadbeef0000.png"), "legacy public original")

      upload = %Plug.Upload{filename: "shot.png", path: src, content_type: "image/png"}
      assert {:ok, stored} = Vutuv.Screenshot.store({upload, @url})
      hash = Path.rootname(stored)

      assert File.ls!(dir) == ["thumb-#{hash}.avif"]
    end
  end
end
