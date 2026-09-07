defmodule Vutuv.AvatarTest do
  @moduledoc """
  Locks the on-disk and URL conventions for avatars.

  Served versions are AVIF (per `Vutuv.Uploads.Spec`) at the stable, id-scoped
  `avatars/<user.id>/avatar_<version>.avif` under the storage root, served by
  nginx (`location /avatars/`). The filename does not embed the display name,
  so renaming a profile never orphans it (issue #773). The uploaded
  **original** is kept verbatim at `originals/avatars/<user.id>/original<ext>`
  — a private tree that is never served, so nobody can download the
  full-resolution upload (with its EXIF/GPS metadata).

  Files written by an earlier pipeline (pre-AVIF `_thumb.jpg`, or the pre-#773
  name-derived `<First Last>_thumb.avif`) keep resolving through a transitional
  fallback until `Vutuv.Uploads.Regenerator` has re-derived them under the
  stable name.

  Every URL here is built from the picture's row in the shared `images` table
  (`Vutuv.Images`, issue #2027), so each test hangs a row on the member struct
  with `Vutuv.ImageHelpers.put_image/3` instead of setting a member column.
  """
  # Not async: these tests set the global `:uploads_dir_prefix` application env.
  use ExUnit.Case, async: false

  import Vutuv.ImageHelpers

  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.MutableImage
  alias Vutuv.Accounts.User
  alias Vutuv.Uploads.Spec

  @user %User{
    id: 7,
    first_name: "John",
    last_name: "Doe",
    username: "john.doe",
    updated_at: ~N[2024-03-02 10:20:30]
  }

  # Cache-busting suffix appended to every served avatar/cover URL, derived from
  # the scope's `updated_at` so a re-upload (which bumps `updated_at`) changes
  # the URL and defeats the 30-day browser/nginx cache. See
  # `Vutuv.Uploads.served_url/4`. Constant here because `@user.updated_at` is.
  @v "?v=#{:erlang.phash2(~N[2024-03-02 10:20:30])}"

  # A stand-in content fingerprint (sha256(original)[0..11]) for scheme B: when
  # the picture's row carries one, the served filename bakes in the handle +
  # fingerprint and the URL drops the `?v=` (Vutuv.Uploads). 12 lowercase hex
  # chars, like the real thing and like Vutuv.Screenshot.
  @fingerprint "1a2b3c4d5e6f"

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
    test "builds the stable, id-scoped version path with the served .avif extension" do
      assert Vutuv.Avatar.url(avatar(@user, file: "selfie.jpg"), :thumb) ==
               "/avatars/7/avatar_thumb.avif" <> @v

      assert Vutuv.Avatar.url(avatar(@user, file: "selfie.jpg"), :medium) ==
               "/avatars/7/avatar_medium.avif" <> @v
    end

    test "the served filename does not embed the display name, so a rename keeps it (issue #773)" do
      renamed = %{@user | first_name: "Jane", last_name: "Smith"}

      assert Vutuv.Avatar.url(avatar(renamed, file: "selfie.jpg"), :thumb) ==
               "/avatars/7/avatar_thumb.avif" <> @v
    end

    test "the stored filename's extension does not leak into served URLs" do
      assert Vutuv.Avatar.url(avatar(@user, file: "selfie.PNG"), :medium) ==
               "/avatars/7/avatar_medium.avif" <> @v
    end

    test "the original is not URL-addressable" do
      assert Vutuv.Avatar.url(avatar(@user, file: "selfie.jpg"), :original) == nil
    end

    test "returns nil when there is no avatar" do
      assert Vutuv.Avatar.url(without_image(@user, "avatar"), :thumb) == nil
    end

    test "default version is :medium" do
      assert Vutuv.Avatar.url(avatar(@user, file: "selfie.jpg")) ==
               "/avatars/7/avatar_medium.avif" <> @v
    end

    test "falls back to a not-yet-regenerated legacy file (incl. ?timestamp suffix)", %{tmp: tmp} do
      dir = Path.join(tmp, "avatars/7")
      File.mkdir_p!(dir)
      {:ok, img} = Image.new(20, 20, color: [1, 2, 3])
      {:ok, _} = Image.write(img, Path.join(dir, "John Doe_thumb.jpg"))

      assert Vutuv.Avatar.url(avatar(@user, file: "selfie.jpg?63876543210"), :thumb) ==
               "/avatars/7/John%20Doe_thumb.jpg" <> @v

      # The name-derived .avif wins over the pre-AVIF legacy file.
      {:ok, _} = Image.write(img, Path.join(dir, "John Doe_thumb.avif"))

      assert Vutuv.Avatar.url(avatar(@user, file: "selfie.jpg?63876543210"), :thumb) ==
               "/avatars/7/John%20Doe_thumb.avif" <> @v

      # ...and once the regenerator has written the stable id-scoped file, that
      # wins over every name-derived legacy file (issue #773).
      {:ok, _} = Image.write(img, Path.join(dir, "avatar_thumb.avif"))

      assert Vutuv.Avatar.url(avatar(@user, file: "selfie.jpg?63876543210"), :thumb) ==
               "/avatars/7/avatar_thumb.avif" <> @v
    end
  end

  describe "cache-busting (a re-upload must not keep showing the cached image)" do
    test "appends a ?v= token derived from the scope's updated_at" do
      assert Vutuv.Avatar.url(avatar(@user, file: "selfie.jpg"), :medium) ==
               "/avatars/7/avatar_medium.avif?v=#{:erlang.phash2(@user.updated_at)}"
    end

    test "the token changes when updated_at changes (so the URL does too)" do
      touched = %{@user | updated_at: ~N[2024-03-02 10:20:31]}

      refute Vutuv.Avatar.url(avatar(touched, file: "selfie.jpg"), :medium) ==
               Vutuv.Avatar.url(avatar(@user, file: "selfie.jpg"), :medium)
    end

    test "the token is stable for an unchanged updated_at (URL stays cacheable)" do
      assert Vutuv.Avatar.url(avatar(@user, file: "selfie.jpg"), :medium) ==
               Vutuv.Avatar.url(avatar(@user, file: "selfie.jpg"), :medium)
    end

    test "no token when the scope carries no updated_at (e.g. an unpersisted struct)" do
      assert Vutuv.Avatar.url(avatar(%{@user | updated_at: nil}, file: "selfie.jpg"), :medium) ==
               "/avatars/7/avatar_medium.avif"
    end
  end

  describe "fingerprinted URL (scheme B: handle + content hash in the filename)" do
    setup do
      {:ok, user: avatar(@user, file: "selfie.jpg", fingerprint: @fingerprint)}
    end

    test "bakes <handle>-<version>-<fingerprint>.avif and drops the ?v= query", %{user: user} do
      assert Vutuv.Avatar.url(user, :medium) ==
               "/avatars/7/john.doe-medium-#{@fingerprint}.avif"

      assert Vutuv.Avatar.url(user, :thumb) ==
               "/avatars/7/john.doe-thumb-#{@fingerprint}.avif"

      refute Vutuv.Avatar.url(user, :medium) =~ "?"
    end

    test "the download filename moves with the handle when the slug changes", %{user: user} do
      renamed = %{user | username: "jane.smith"}

      assert Vutuv.Avatar.url(renamed, :medium) ==
               "/avatars/7/jane.smith-medium-#{@fingerprint}.avif"
    end

    test "a new fingerprint changes the URL (the cache-buster lives in the name)", %{user: user} do
      reuploaded = avatar(@user, file: "selfie.jpg", fingerprint: "ffffffffffff")

      refute Vutuv.Avatar.url(reuploaded, :medium) == Vutuv.Avatar.url(user, :medium)
    end

    test "display_url/2 emits the fingerprinted URL", %{user: user} do
      assert Vutuv.Avatar.display_url(user, :medium) ==
               "/avatars/7/john.doe-medium-#{@fingerprint}.avif"
    end

    test "a picture row with no fingerprint still serves the legacy ?v= URL (not yet migrated)" do
      assert Vutuv.Avatar.url(avatar(@user, file: "selfie.jpg"), :medium) ==
               "/avatars/7/avatar_medium.avif" <> @v
    end
  end

  describe "binary/2 (base64 JPEG used by the vCard export)" do
    test "returns the default SVG data URI when the user has no avatar" do
      data = Vutuv.Avatar.binary(without_image(@user, "avatar"), :thumb)
      assert String.starts_with?(data, "data:image/svg+xml,")
    end

    test "returns the default SVG when the original is missing on disk" do
      data = Vutuv.Avatar.binary(avatar(@user, file: "missing.jpg"), :thumb)
      assert String.starts_with?(data, "data:image/svg+xml,")
    end

    test "derives a JPEG from the private original (contact apps cannot show AVIF)", %{tmp: tmp} do
      dir = Path.join(tmp, "originals/avatars/7")
      File.mkdir_p!(dir)
      {:ok, img} = Image.new(300, 200, color: [1, 2, 3])
      {:ok, _} = Image.write(img, Path.join(dir, "original.jpg"))

      assert "data:image/jpeg;base64," <> data =
               Vutuv.Avatar.binary(avatar(@user, file: "orig.jpg"), :thumb)

      assert {:ok, _} = Base.decode64(data)
    end

    test "a PNG original still yields a JPEG photo", %{tmp: tmp} do
      dir = Path.join(tmp, "originals/avatars/7")
      File.mkdir_p!(dir)
      {:ok, img} = Image.new(300, 200, color: [1, 2, 3])
      {:ok, _} = Image.write(img, Path.join(dir, "original.png"))

      assert "data:image/jpeg;base64," <> _ =
               Vutuv.Avatar.binary(avatar(@user, file: "orig.png"), :thumb)
    end

    test "the derived JPEG carries no EXIF from the original", %{tmp: tmp} do
      dir = Path.join(tmp, "originals/avatars/7")
      File.mkdir_p!(dir)
      {:ok, img} = Image.new(300, 200, color: [1, 2, 3])

      {:ok, tagged} =
        Image.mutate(img, fn mut ->
          :ok = MutableImage.set(mut, "exif-ifd0-Make", :gchararray, "TestCam")
        end)

      {:ok, _} = Image.write(tagged, Path.join(dir, "original.jpg"))

      assert "data:image/jpeg;base64," <> data =
               Vutuv.Avatar.binary(avatar(@user, file: "orig.jpg"), :thumb)

      {:ok, jpeg} = data |> Base.decode64!() |> Image.from_binary()
      {:ok, fields} = VipsImage.header_field_names(jpeg)
      assert Enum.filter(fields, &String.contains?(&1, "exif")) == []
    end
  end

  describe "og_jpeg/1 (the /:slug/avatar.jpg link-preview bytes)" do
    test "derives a square JPEG at og_size from the original", %{tmp: tmp} do
      dir = Path.join(tmp, "originals/avatars/7")
      File.mkdir_p!(dir)
      {:ok, img} = Image.new(600, 400, color: [10, 120, 200])
      {:ok, _} = Image.write(img, Path.join(dir, "original.jpg"))

      assert {:ok, data} = Vutuv.Avatar.og_jpeg(avatar(@user, file: "orig.jpg"))
      {:ok, jpeg} = Image.from_binary(data)
      size = Vutuv.Avatar.og_size()
      assert {Image.width(jpeg), Image.height(jpeg)} == {size, size}
    end

    test "falls back to a served version when no original was kept (legacy uploads)", %{
      tmp: tmp
    } do
      dir = Path.join(tmp, "avatars/7")
      File.mkdir_p!(dir)
      {:ok, img} = Image.new(192, 192, color: [10, 120, 200])
      {:ok, _} = Image.write(img, Path.join(dir, "John Doe_medium.avif"))

      assert {:ok, data} = Vutuv.Avatar.og_jpeg(avatar(@user, file: "selfie.jpg"))
      {:ok, jpeg} = Image.from_binary(data)
      assert Image.width(jpeg) == Vutuv.Avatar.og_size()
    end

    test ":error without an avatar or with nothing usable on disk" do
      assert Vutuv.Avatar.og_jpeg(without_image(@user, "avatar")) == :error
      assert Vutuv.Avatar.og_jpeg(avatar(@user, file: "missing.jpg")) == :error
    end
  end

  describe "display_url/2 (what templates put in <img src>)" do
    test "returns the nginx-served URL when the user has an avatar" do
      user = avatar(@user, file: "selfie.jpg")
      assert Vutuv.Avatar.display_url(user, :medium) == "/avatars/7/avatar_medium.avif" <> @v
    end

    test "falls back to the default SVG when the user has no avatar" do
      data = Vutuv.Avatar.display_url(without_image(@user, "avatar"), :thumb)
      assert String.starts_with?(data, "data:image/svg+xml,")
    end
  end

  # The lite version (data-saving mode, `Vutuv.LowBandwidth`) of the 96 CSS px
  # profile picture: the 96 px thumb, offered only when its file is there.
  describe "picture/1" do
    setup do
      {:ok, user: avatar(@user, file: "selfie.jpg", fingerprint: @fingerprint)}
    end

    test "is the picture alone outside data-saving mode", %{user: user} do
      Vutuv.LowBandwidth.put(false)

      assert Vutuv.Avatar.picture(user) ==
               %{src: "/avatars/7/john.doe-medium-#{@fingerprint}.avif", lite: nil}
    end

    test "offers the thumb as the lite in data-saving mode once its file exists", %{
      tmp: tmp,
      user: user
    } do
      Vutuv.LowBandwidth.put(true)
      assert Vutuv.Avatar.picture(user).lite == nil

      dir = Path.join(tmp, "avatars/7")
      File.mkdir_p!(dir)
      {:ok, img} = Image.new(20, 20, color: [1, 2, 3])
      {:ok, _} = Image.write(img, Path.join(dir, "john.doe-thumb-#{@fingerprint}.avif"))

      assert Vutuv.Avatar.picture(user) == %{
               src: "/avatars/7/john.doe-medium-#{@fingerprint}.avif",
               lite: "/avatars/7/john.doe-thumb-#{@fingerprint}.avif"
             }
    end

    # A member with no picture at all is now told apart from one nobody may see:
    # the row answers since #2027, so this one has no `src` and the caller draws
    # its initials tile, while the silhouette stays for a picture on hold.
    test "without an avatar there is nothing to show, and no lite either way" do
      Vutuv.LowBandwidth.put(true)
      assert Vutuv.Avatar.picture(without_image(@user, "avatar")) == %{src: nil, lite: nil}
    end

    test "an avatar the AI gate still holds shows the silhouette, and no lite" do
      Vutuv.LowBandwidth.put(true)
      held = avatar(@user, file: "selfie.jpg", fingerprint: @fingerprint, moderation: "pending")

      assert %{src: src, lite: nil} = Vutuv.Avatar.picture(held)
      assert String.starts_with?(src, "data:image/svg+xml,")
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

    test "writes fingerprinted AVIF versions publicly and the original privately",
         %{tmp: tmp, src: src} do
      upload = %Plug.Upload{filename: "selfie.jpg", path: src, content_type: "image/jpeg"}
      assert {:ok, "selfie.jpg", fp, _} = Vutuv.Avatar.store({upload, @user})
      assert fp =~ ~r/\A[0-9a-f]{12}\z/

      dir = Path.join(tmp, "avatars/7")
      assert File.exists?(Path.join(dir, "john.doe-thumb-#{fp}.avif"))
      assert File.exists?(Path.join(dir, "john.doe-medium-#{fp}.avif"))
      assert File.exists?(Path.join(tmp, "originals/avatars/7/original.jpg"))

      # Nothing original may land in the publicly served tree.
      assert dir |> File.ls!() |> Enum.filter(&String.contains?(&1, "original")) == []
    end

    test "the returned fingerprint is what url/2 then serves (write == URL)", %{src: src} do
      upload = %Plug.Upload{filename: "selfie.jpg", path: src, content_type: "image/jpeg"}
      assert {:ok, file_name, fp, _} = Vutuv.Avatar.store({upload, @user})
      stored = avatar(@user, file: file_name, fingerprint: fp)

      assert Vutuv.Avatar.url(stored, :medium) == "/avatars/7/john.doe-medium-#{fp}.avif"
    end

    test "a re-upload clears the prior fingerprinted versions (no accumulation)",
         %{tmp: tmp, src: src} do
      upload = %Plug.Upload{filename: "selfie.jpg", path: src, content_type: "image/jpeg"}
      assert {:ok, _, _fp1, _} = Vutuv.Avatar.store({upload, @user})

      png = Path.join(System.tmp_dir!(), "src_#{System.unique_integer([:positive])}.png")
      {:ok, img} = Image.new(400, 400, color: [9, 9, 9])
      {:ok, _} = Image.write(img, png)
      on_exit(fn -> File.rm(png) end)
      upload2 = %Plug.Upload{filename: "new.png", path: png, content_type: "image/png"}
      assert {:ok, _, fp2, _} = Vutuv.Avatar.store({upload2, @user})

      # Exactly the versions of the latest upload remain — read from the spec,
      # so adding one (the `:large` of issue #1528) does not read as accumulation.
      assert Path.join(tmp, "avatars/7") |> File.ls!() |> Enum.sort() ==
               Enum.sort(
                 for spec <- Spec.versions(:avatar), do: "john.doe-#{spec.name}-#{fp2}.avif"
               )
    end

    test "a re-upload with a different extension leaves no stale private original", %{
      tmp: tmp,
      src: src
    } do
      upload = %Plug.Upload{filename: "selfie.jpg", path: src, content_type: "image/jpeg"}
      assert {:ok, _, _, _} = Vutuv.Avatar.store({upload, @user})

      png = Path.join(System.tmp_dir!(), "src_#{System.unique_integer([:positive])}.png")
      {:ok, img} = Image.new(300, 300, color: [1, 2, 3])
      {:ok, _} = Image.write(img, png)
      on_exit(fn -> File.rm(png) end)
      upload2 = %Plug.Upload{filename: "new.png", path: png, content_type: "image/png"}
      assert {:ok, _, _, _} = Vutuv.Avatar.store({upload2, @user})

      assert File.ls!(Path.join(tmp, "originals/avatars/7")) == ["original.png"]
    end

    test "thumb/medium are cropped to the Spec dimensions", %{tmp: tmp, src: src} do
      upload = %Plug.Upload{filename: "selfie.jpg", path: src, content_type: "image/jpeg"}
      assert {:ok, _, fp, _} = Vutuv.Avatar.store({upload, @user})

      dir = Path.join(tmp, "avatars/7")
      assert dimensions(Path.join(dir, "john.doe-thumb-#{fp}.avif")) == {96, 96}
      assert dimensions(Path.join(dir, "john.doe-medium-#{fp}.avif")) == {192, 192}
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
      assert {:ok, _, fp, _} = Vutuv.Avatar.store({upload, @user})

      {:ok, stored} = Image.open(Path.join(tmp, "avatars/7/john.doe-thumb-#{fp}.avif"))
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

  # This member with an avatar row hung on the struct, which is what every URL
  # builder reads since #2027 (`Vutuv.Images.member_image/2`). No database:
  # nothing here inserts a member.
  defp avatar(user, attrs), do: put_image(user, "avatar", attrs)

  defp dimensions(path) do
    {:ok, img} = Image.open(path)
    {Image.width(img), Image.height(img)}
  end
end
