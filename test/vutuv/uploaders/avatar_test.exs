defmodule Vutuv.AvatarTest do
  @moduledoc """
  Locks the on-disk and URL conventions for avatars so existing production
  images keep resolving after Waffle was replaced by local storage + libvips.

  Production avatars live at `avatars/<user.id>/<First Last>_<version><ext>`
  under the storage root and are served by nginx (`location /avatars/`). The
  exact filename, extension and URI-encoding therefore must not change.
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
    test "builds the version path with the user's name and original extension" do
      assert Vutuv.Avatar.url({"selfie.jpg", @user}, :thumb) ==
               "/avatars/7/John%20Doe_thumb.jpg"

      assert Vutuv.Avatar.url({"selfie.jpg", @user}, :original) ==
               "/avatars/7/John%20Doe_original.jpg"

      assert Vutuv.Avatar.url({"selfie.jpg", @user}, :medium) ==
               "/avatars/7/John%20Doe_medium.jpg"

      assert Vutuv.Avatar.url({"selfie.jpg", @user}, :large) ==
               "/avatars/7/John%20Doe_large.jpg"
    end

    test "preserves the original extension verbatim (incl. case)" do
      assert Vutuv.Avatar.url({"selfie.PNG", @user}, :medium) ==
               "/avatars/7/John%20Doe_medium.PNG"
    end

    test "tolerates the legacy `?<timestamp>` suffix stored by Waffle.Ecto" do
      assert Vutuv.Avatar.url({"selfie.jpg?63876543210", @user}, :thumb) ==
               "/avatars/7/John%20Doe_thumb.jpg"
    end

    test "returns nil when there is no avatar" do
      assert Vutuv.Avatar.url({nil, @user}, :original) == nil
    end

    test "default version is :original" do
      assert Vutuv.Avatar.url({"selfie.jpg", @user}) ==
               "/avatars/7/John%20Doe_original.jpg"
    end
  end

  test "urls/1 returns every version" do
    urls = Vutuv.Avatar.urls({"selfie.jpg", @user})
    assert urls[:original] == "/avatars/7/John%20Doe_original.jpg"
    assert urls[:thumb] == "/avatars/7/John%20Doe_thumb.jpg"
    assert urls[:medium] == "/avatars/7/John%20Doe_medium.jpg"
    assert urls[:large] == "/avatars/7/John%20Doe_large.jpg"
  end

  test "user_url/2 reads the avatar field off the user" do
    user = %{@user | avatar: "selfie.jpg"}
    assert Vutuv.Avatar.user_url(user, :large) == "/avatars/7/John%20Doe_large.jpg"
  end

  describe "binary/2 (base64 fallback used by vCard and dev)" do
    test "returns the default SVG data URI when the user has no avatar" do
      data = Vutuv.Avatar.binary(%{@user | avatar: nil}, :thumb)
      assert String.starts_with?(data, "data:image/svg+xml,")
    end

    test "returns the default SVG when the file is missing on disk" do
      data = Vutuv.Avatar.binary(%{@user | avatar: "missing.jpg"}, :thumb)
      assert String.starts_with?(data, "data:image/svg+xml,")
    end

    test "reads the real file under the storage prefix and base64-encodes it", %{tmp: tmp} do
      dir = Path.join(tmp, "avatars/7")
      File.mkdir_p!(dir)
      {:ok, img} = Image.new(20, 20, color: [1, 2, 3])
      {:ok, _} = Image.write(img, Path.join(dir, "John Doe_thumb.jpg"))

      assert "data:image/jpeg;base64," <> data =
               Vutuv.Avatar.binary(%{@user | avatar: "orig.jpg"}, :thumb)

      assert {:ok, _} = Base.decode64(data)
    end

    test "uses image/png for png avatars (not image/jpg)", %{tmp: tmp} do
      dir = Path.join(tmp, "avatars/7")
      File.mkdir_p!(dir)
      {:ok, img} = Image.new(20, 20, color: [1, 2, 3])
      {:ok, _} = Image.write(img, Path.join(dir, "John Doe_thumb.png"))

      assert "data:image/png;base64," <> _ =
               Vutuv.Avatar.binary(%{@user | avatar: "orig.png"}, :thumb)
    end
  end

  describe "display_url/2 (what templates put in <img src>)" do
    test "returns the nginx-served URL when the user has an avatar" do
      user = %{@user | avatar: "selfie.jpg"}
      assert Vutuv.Avatar.display_url(user, :medium) == "/avatars/7/John%20Doe_medium.jpg"
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

    test "writes every version to the user's directory with the right names", %{
      tmp: tmp,
      src: src
    } do
      upload = %Plug.Upload{filename: "selfie.jpg", path: src, content_type: "image/jpeg"}
      assert {:ok, "selfie.jpg"} = Vutuv.Avatar.store({upload, @user})

      dir = Path.join(tmp, "avatars/7")

      for v <- ~w(original thumb medium large) do
        assert File.exists?(Path.join(dir, "John Doe_#{v}.jpg")), "missing #{v}"
      end
    end

    test "thumb/medium/large are cropped to the configured square dimensions", %{
      tmp: tmp,
      src: src
    } do
      upload = %Plug.Upload{filename: "selfie.jpg", path: src, content_type: "image/jpeg"}
      assert {:ok, _} = Vutuv.Avatar.store({upload, @user})

      dir = Path.join(tmp, "avatars/7")
      assert dimensions(Path.join(dir, "John Doe_thumb.jpg")) == {50, 50}
      assert dimensions(Path.join(dir, "John Doe_medium.jpg")) == {130, 130}
      assert dimensions(Path.join(dir, "John Doe_large.jpg")) == {512, 512}
    end

    test "rejects files whose extension is not whitelisted", %{src: src} do
      upload = %Plug.Upload{filename: "evil.gif", path: src, content_type: "image/gif"}
      assert {:error, _} = Vutuv.Avatar.store({upload, @user})
    end
  end

  defp dimensions(path) do
    {:ok, img} = Image.open(path)
    {Image.width(img), Image.height(img)}
  end
end
