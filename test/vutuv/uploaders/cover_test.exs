defmodule Vutuv.CoverTest do
  @moduledoc """
  Locks the on-disk and URL conventions for profile cover photos. Covers live at
  `covers/<user.id>/<First Last>_<version><ext>` under the storage root and are
  served by nginx (`location /covers/`), mirroring avatars. The exact filename,
  extension and URI-encoding therefore must not change.
  """
  # Not async: these tests set the global `:uploads_dir_prefix` application env.
  use ExUnit.Case, async: false

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
    test "builds the version path with the user's name and original extension" do
      assert Vutuv.Cover.url({"banner.jpg", @user}, :wide) ==
               "/covers/7/John%20Doe_wide.jpg"

      assert Vutuv.Cover.url({"banner.jpg", @user}, :original) ==
               "/covers/7/John%20Doe_original.jpg"
    end

    test "preserves the original extension verbatim (incl. case)" do
      assert Vutuv.Cover.url({"banner.PNG", @user}, :wide) ==
               "/covers/7/John%20Doe_wide.PNG"
    end

    test "tolerates the legacy `?<timestamp>` suffix" do
      assert Vutuv.Cover.url({"banner.jpg?63876543210", @user}, :wide) ==
               "/covers/7/John%20Doe_wide.jpg"
    end

    test "returns nil when there is no cover photo" do
      assert Vutuv.Cover.url({nil, @user}, :wide) == nil
    end

    test "default version is :wide" do
      assert Vutuv.Cover.url({"banner.jpg", @user}) == "/covers/7/John%20Doe_wide.jpg"
    end
  end

  describe "display_url/2 (what the profile puts in <img src>)" do
    test "returns the nginx-served URL when the user has a cover photo" do
      user = %{@user | cover_photo: "banner.jpg"}
      assert Vutuv.Cover.display_url(user, :wide) == "/covers/7/John%20Doe_wide.jpg"
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

    test "writes the wide and original versions to the user's directory", %{tmp: tmp, src: src} do
      upload = %Plug.Upload{filename: "banner.jpg", path: src, content_type: "image/jpeg"}
      assert {:ok, "banner.jpg"} = Vutuv.Cover.store({upload, @user})

      dir = Path.join(tmp, "covers/7")
      assert File.exists?(Path.join(dir, "John Doe_wide.jpg"))
      assert File.exists?(Path.join(dir, "John Doe_original.jpg"))
    end

    test "the wide version is capped at 1600px wide, preserving aspect ratio", %{
      tmp: tmp,
      src: src
    } do
      upload = %Plug.Upload{filename: "banner.jpg", path: src, content_type: "image/jpeg"}
      assert {:ok, _} = Vutuv.Cover.store({upload, @user})

      # Source is 1200 wide (< 1600), so it is not upscaled; aspect ratio holds.
      {w, h} = dimensions(Path.join(tmp, "covers/7/John Doe_wide.jpg"))
      assert w == 1200
      assert h == 600
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
      refute File.exists?(Path.join(tmp, "covers/7/John Doe_original.png"))
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
