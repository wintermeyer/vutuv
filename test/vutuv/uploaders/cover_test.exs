defmodule Vutuv.CoverTest do
  @moduledoc """
  Locks the on-disk and URL conventions for profile cover photos, mirroring
  avatars: served versions are AVIF (per `Vutuv.Uploads.Spec`) at
  `covers/<user.id>/<First Last>_<version>.avif` (nginx `location /covers/`),
  the uploaded original is kept privately at
  `originals/covers/<user.id>/original<ext>` and is never served.
  """
  # Not async: these tests set the global `:uploads_dir_prefix` application env.
  use ExUnit.Case, async: false

  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.MutableImage
  alias Vutuv.Accounts.User

  @user %User{
    id: 7,
    first_name: "John",
    last_name: "Doe",
    active_slug: "john.doe",
    updated_at: ~N[2024-03-02 10:20:30]
  }

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_cover_test_#{System.unique_integer([:positive])}")
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

  describe "url/2 (the contract nginx + templates depend on)" do
    test "builds the version path with the user's name and the served .avif extension" do
      assert Vutuv.Cover.url({"banner.jpg", @user}, :wide) ==
               "/covers/7/John%20Doe_wide.avif"
    end

    test "the stored filename's extension does not leak into served URLs" do
      assert Vutuv.Cover.url({"banner.PNG", @user}, :wide) ==
               "/covers/7/John%20Doe_wide.avif"
    end

    test "the original is not URL-addressable" do
      assert Vutuv.Cover.url({"banner.jpg", @user}, :original) == nil
    end

    test "returns nil when there is no cover photo" do
      assert Vutuv.Cover.url({nil, @user}, :wide) == nil
    end

    test "default version is :wide" do
      assert Vutuv.Cover.url({"banner.jpg", @user}) == "/covers/7/John%20Doe_wide.avif"
    end

    test "falls back to a not-yet-regenerated legacy file (incl. ?timestamp suffix)", %{tmp: tmp} do
      dir = Path.join(tmp, "covers/7")
      File.mkdir_p!(dir)
      {:ok, img} = Image.new(20, 20, color: [1, 2, 3])
      {:ok, _} = Image.write(img, Path.join(dir, "John Doe_wide.jpg"))

      assert Vutuv.Cover.url({"banner.jpg?63876543210", @user}, :wide) ==
               "/covers/7/John%20Doe_wide.jpg"

      # Once the .avif exists it wins over the legacy file.
      {:ok, _} = Image.write(img, Path.join(dir, "John Doe_wide.avif"))

      assert Vutuv.Cover.url({"banner.jpg?63876543210", @user}, :wide) ==
               "/covers/7/John%20Doe_wide.avif"
    end
  end

  describe "display_url/2 (what the profile puts in <img src>)" do
    test "returns the nginx-served URL when the user has a cover photo" do
      user = %{@user | cover_photo: "banner.jpg"}
      assert Vutuv.Cover.display_url(user, :wide) == "/covers/7/John%20Doe_wide.avif"
    end

    test "returns nil when the user has no cover photo (gradient fallback)" do
      assert Vutuv.Cover.display_url(%{@user | cover_photo: nil}, :wide) == nil
    end
  end

  describe "store/1" do
    setup do
      # A real 1200x600 JPEG so libvips has something to resize.
      {:ok, img} = Image.new(1200, 600, color: [10, 120, 200])
      src = Path.join(System.tmp_dir!(), "src_#{System.unique_integer([:positive])}.jpg")
      {:ok, _} = Image.write(img, src)
      on_exit(fn -> File.rm(src) end)
      {:ok, src: src}
    end

    test "writes the AVIF wide version publicly and the original privately", %{
      tmp: tmp,
      src: src
    } do
      upload = %Plug.Upload{filename: "banner.jpg", path: src, content_type: "image/jpeg"}
      assert {:ok, "banner.jpg"} = Vutuv.Cover.store({upload, @user})

      dir = Path.join(tmp, "covers/7")
      assert File.exists?(Path.join(dir, "John Doe_wide.avif"))
      assert File.exists?(Path.join(tmp, "originals/covers/7/original.jpg"))

      # Nothing original may land in the publicly served tree.
      assert dir |> File.ls!() |> Enum.filter(&String.contains?(&1, "original")) == []
    end

    test "the wide version is capped at 1600px wide, preserving aspect ratio", %{
      tmp: tmp,
      src: src
    } do
      upload = %Plug.Upload{filename: "banner.jpg", path: src, content_type: "image/jpeg"}
      assert {:ok, _} = Vutuv.Cover.store({upload, @user})

      # Source is 1200 wide (< 1600), so it is not upscaled; aspect ratio holds.
      {w, h} = dimensions(Path.join(tmp, "covers/7/John Doe_wide.avif"))
      assert w == 1200
      assert h == 600
    end

    test "served versions carry no EXIF metadata", %{tmp: tmp} do
      src = Path.join(System.tmp_dir!(), "exif_#{System.unique_integer([:positive])}.jpg")
      {:ok, img} = Image.new(300, 200, color: [200, 30, 30])

      {:ok, tagged} =
        Image.mutate(img, fn mut ->
          :ok = MutableImage.set(mut, "exif-ifd0-Make", :gchararray, "TestCam")
        end)

      {:ok, _} = Image.write(tagged, src)
      on_exit(fn -> File.rm(src) end)

      upload = %Plug.Upload{filename: "banner.jpg", path: src, content_type: "image/jpeg"}
      assert {:ok, _} = Vutuv.Cover.store({upload, @user})

      {:ok, stored} = Image.open(Path.join(tmp, "covers/7/John Doe_wide.avif"))
      {:ok, fields} = VipsImage.header_field_names(stored)
      assert Enum.filter(fields, &String.contains?(&1, "exif")) == []
    end

    test "rejects files whose extension is not whitelisted", %{src: src} do
      upload = %Plug.Upload{filename: "evil.gif", path: src, content_type: "image/gif"}
      assert {:error, :invalid_file} = Vutuv.Cover.store({upload, @user})
    end

    test "returns {:error, :invalid_file} for a corrupt image instead of crashing", %{tmp: tmp} do
      src = Path.join(System.tmp_dir!(), "corrupt_#{System.unique_integer([:positive])}.png")
      File.write!(src, "definitely not a png")
      on_exit(fn -> File.rm(src) end)
      upload = %Plug.Upload{filename: "corrupt.png", path: src, content_type: "image/png"}

      assert {:error, :invalid_file} = Vutuv.Cover.store({upload, @user})
      # nothing half-written: the original is only copied after a successful decode
      refute File.exists?(Path.join(tmp, "originals/covers/7/original.png"))
    end

    test "a corrupt upload surfaces as a friendly changeset error" do
      src = Path.join(System.tmp_dir!(), "corrupt_#{System.unique_integer([:positive])}.png")
      File.write!(src, "definitely not a png")
      on_exit(fn -> File.rm(src) end)
      upload = %Plug.Upload{filename: "corrupt.png", path: src, content_type: "image/png"}

      changeset = User.changeset(@user, %{"cover_photo" => upload})

      refute changeset.valid?
      assert {"is not a valid image", _} = changeset.errors[:cover_photo]
    end
  end

  defp dimensions(path) do
    {:ok, img} = Image.open(path)
    {Image.width(img), Image.height(img)}
  end
end
