defmodule Vutuv.AvatarTest do
  @moduledoc """
  Locks the on-disk and URL conventions for avatars.

  Served versions are AVIF (per `Vutuv.Uploads.Spec`) at
  `avatars/<user.id>/<First Last>_<version>.avif` under the storage root,
  served by nginx (`location /avatars/`). The uploaded **original** is kept
  verbatim at `originals/avatars/<user.id>/original<ext>` — a private tree
  that is never served, so nobody can download the full-resolution upload
  (with its EXIF/GPS metadata).

  Pre-AVIF derived files (`_thumb.jpg` ...) keep resolving through a
  transitional fallback until `Vutuv.Uploads.Regenerator` has converted them.
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
    tmp = Path.join(System.tmp_dir!(), "vutuv_avatar_test_#{System.unique_integer([:positive])}")
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
      assert Vutuv.Avatar.url({"selfie.jpg", @user}, :thumb) ==
               "/avatars/7/John%20Doe_thumb.avif"

      assert Vutuv.Avatar.url({"selfie.jpg", @user}, :medium) ==
               "/avatars/7/John%20Doe_medium.avif"
    end

    test "the stored filename's extension does not leak into served URLs" do
      assert Vutuv.Avatar.url({"selfie.PNG", @user}, :medium) ==
               "/avatars/7/John%20Doe_medium.avif"
    end

    test "the original is not URL-addressable" do
      assert Vutuv.Avatar.url({"selfie.jpg", @user}, :original) == nil
    end

    test "returns nil when there is no avatar" do
      assert Vutuv.Avatar.url({nil, @user}, :thumb) == nil
    end

    test "default version is :medium" do
      assert Vutuv.Avatar.url({"selfie.jpg", @user}) ==
               "/avatars/7/John%20Doe_medium.avif"
    end

    test "falls back to a not-yet-regenerated legacy file (incl. ?timestamp suffix)", %{tmp: tmp} do
      dir = Path.join(tmp, "avatars/7")
      File.mkdir_p!(dir)
      {:ok, img} = Image.new(20, 20, color: [1, 2, 3])
      {:ok, _} = Image.write(img, Path.join(dir, "John Doe_thumb.jpg"))

      assert Vutuv.Avatar.url({"selfie.jpg?63876543210", @user}, :thumb) ==
               "/avatars/7/John%20Doe_thumb.jpg"

      # Once the .avif exists it wins over the legacy file.
      {:ok, _} = Image.write(img, Path.join(dir, "John Doe_thumb.avif"))

      assert Vutuv.Avatar.url({"selfie.jpg?63876543210", @user}, :thumb) ==
               "/avatars/7/John%20Doe_thumb.avif"
    end
  end

  test "user_url/2 reads the avatar field off the user" do
    user = %{@user | avatar: "selfie.jpg"}
    assert Vutuv.Avatar.user_url(user, :medium) == "/avatars/7/John%20Doe_medium.avif"
  end

  describe "binary/2 (base64 JPEG used by the vCard export)" do
    test "returns the default SVG data URI when the user has no avatar" do
      data = Vutuv.Avatar.binary(%{@user | avatar: nil}, :thumb)
      assert String.starts_with?(data, "data:image/svg+xml,")
    end

    test "returns the default SVG when the original is missing on disk" do
      data = Vutuv.Avatar.binary(%{@user | avatar: "missing.jpg"}, :thumb)
      assert String.starts_with?(data, "data:image/svg+xml,")
    end

    test "derives a JPEG from the private original (contact apps cannot show AVIF)", %{tmp: tmp} do
      dir = Path.join(tmp, "originals/avatars/7")
      File.mkdir_p!(dir)
      {:ok, img} = Image.new(300, 200, color: [1, 2, 3])
      {:ok, _} = Image.write(img, Path.join(dir, "original.jpg"))

      assert "data:image/jpeg;base64," <> data =
               Vutuv.Avatar.binary(%{@user | avatar: "orig.jpg"}, :thumb)

      assert {:ok, _} = Base.decode64(data)
    end

    test "a PNG original still yields a JPEG photo", %{tmp: tmp} do
      dir = Path.join(tmp, "originals/avatars/7")
      File.mkdir_p!(dir)
      {:ok, img} = Image.new(300, 200, color: [1, 2, 3])
      {:ok, _} = Image.write(img, Path.join(dir, "original.png"))

      assert "data:image/jpeg;base64," <> _ =
               Vutuv.Avatar.binary(%{@user | avatar: "orig.png"}, :thumb)
    end
  end

  describe "display_url/2 (what templates put in <img src>)" do
    test "returns the nginx-served URL when the user has an avatar" do
      user = %{@user | avatar: "selfie.jpg"}
      assert Vutuv.Avatar.display_url(user, :medium) == "/avatars/7/John%20Doe_medium.avif"
    end

    test "falls back to the default SVG when the user has no avatar" do
      data = Vutuv.Avatar.display_url(%{@user | avatar: nil}, :thumb)
      assert String.starts_with?(data, "data:image/svg+xml,")
    end
  end

  describe "store/1" do
    setup do
      # A real 600x400 JPEG so libvips has something to resize.
      {:ok, img} = Image.new(600, 400, color: [10, 120, 200])
      src = Path.join(System.tmp_dir!(), "src_#{System.unique_integer([:positive])}.jpg")
      {:ok, _} = Image.write(img, src)
      on_exit(fn -> File.rm(src) end)
      {:ok, src: src}
    end

    test "writes AVIF versions publicly and the original privately", %{tmp: tmp, src: src} do
      upload = %Plug.Upload{filename: "selfie.jpg", path: src, content_type: "image/jpeg"}
      assert {:ok, "selfie.jpg"} = Vutuv.Avatar.store({upload, @user})

      dir = Path.join(tmp, "avatars/7")
      assert File.exists?(Path.join(dir, "John Doe_thumb.avif"))
      assert File.exists?(Path.join(dir, "John Doe_medium.avif"))
      assert File.exists?(Path.join(tmp, "originals/avatars/7/original.jpg"))

      # Nothing original may land in the publicly served tree.
      assert dir |> File.ls!() |> Enum.filter(&String.contains?(&1, "original")) == []
    end

    test "a re-upload with a different extension leaves no stale private original", %{
      tmp: tmp,
      src: src
    } do
      upload = %Plug.Upload{filename: "selfie.jpg", path: src, content_type: "image/jpeg"}
      assert {:ok, _} = Vutuv.Avatar.store({upload, @user})

      png = Path.join(System.tmp_dir!(), "src_#{System.unique_integer([:positive])}.png")
      {:ok, img} = Image.new(300, 300, color: [1, 2, 3])
      {:ok, _} = Image.write(img, png)
      on_exit(fn -> File.rm(png) end)
      upload2 = %Plug.Upload{filename: "new.png", path: png, content_type: "image/png"}
      assert {:ok, _} = Vutuv.Avatar.store({upload2, @user})

      assert File.ls!(Path.join(tmp, "originals/avatars/7")) == ["original.png"]
    end

    test "thumb/medium are cropped to the Spec dimensions", %{tmp: tmp, src: src} do
      upload = %Plug.Upload{filename: "selfie.jpg", path: src, content_type: "image/jpeg"}
      assert {:ok, _} = Vutuv.Avatar.store({upload, @user})

      dir = Path.join(tmp, "avatars/7")
      assert dimensions(Path.join(dir, "John Doe_thumb.avif")) == {96, 96}
      assert dimensions(Path.join(dir, "John Doe_medium.avif")) == {192, 192}
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

      upload = %Plug.Upload{filename: "selfie.jpg", path: src, content_type: "image/jpeg"}
      assert {:ok, _} = Vutuv.Avatar.store({upload, @user})

      {:ok, stored} = Image.open(Path.join(tmp, "avatars/7/John Doe_thumb.avif"))
      {:ok, fields} = VipsImage.header_field_names(stored)
      assert Enum.filter(fields, &String.contains?(&1, "exif")) == []
    end

    test "rejects files whose extension is not whitelisted", %{src: src} do
      upload = %Plug.Upload{filename: "evil.gif", path: src, content_type: "image/gif"}
      assert {:error, _} = Vutuv.Avatar.store({upload, @user})
    end

    test "returns {:error, :invalid_file} for a corrupt image instead of crashing", %{tmp: tmp} do
      src = Path.join(System.tmp_dir!(), "corrupt_#{System.unique_integer([:positive])}.png")
      File.write!(src, "definitely not a png")
      on_exit(fn -> File.rm(src) end)
      upload = %Plug.Upload{filename: "corrupt.png", path: src, content_type: "image/png"}

      assert {:error, :invalid_file} = Vutuv.Avatar.store({upload, @user})
      # nothing half-written: the original is only copied after a successful decode
      refute File.exists?(Path.join(tmp, "originals/avatars/7/original.png"))
    end

    test "a corrupt upload surfaces as a friendly changeset error" do
      src = Path.join(System.tmp_dir!(), "corrupt_#{System.unique_integer([:positive])}.png")
      File.write!(src, "definitely not a png")
      on_exit(fn -> File.rm(src) end)
      upload = %Plug.Upload{filename: "corrupt.png", path: src, content_type: "image/png"}

      changeset = User.changeset(@user, %{"avatar" => upload})

      refute changeset.valid?
      assert {"is not a valid image", _} = changeset.errors[:avatar]
    end
  end

  defp dimensions(path) do
    {:ok, img} = Image.open(path)
    {Image.width(img), Image.height(img)}
  end
end
