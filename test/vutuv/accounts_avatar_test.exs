defmodule Vutuv.AccountsAvatarTest do
  @moduledoc """
  Avatar/cover uploads are written to disk only after the row commits, so a
  rolled-back profile update never orphans files (issue #776, 4a).
  """

  # Not async: points the global :uploads_dir_prefix at a tmp dir.
  use Vutuv.DataCase, async: false

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Uploads

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "vutuv_accounts_avatar_#{System.unique_integer([:positive])}")

    prev = Application.get_env(:vutuv, :uploads_dir_prefix)
    Application.put_env(:vutuv, :uploads_dir_prefix, tmp)

    on_exit(fn ->
      File.rm_rf(tmp)
      if prev, do: Application.put_env(:vutuv, :uploads_dir_prefix, prev)
    end)

    :ok
  end

  # A real, decodable JPEG upload (so it passes the in-changeset validation).
  defp jpeg_upload(name \\ "selfie.jpg") do
    src = Path.join(System.tmp_dir!(), "src_#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(600, 400, color: [10, 120, 200])
    {:ok, _} = Image.write(img, src)
    on_exit(fn -> File.rm(src) end)
    %Plug.Upload{filename: name, path: src, content_type: "image/jpeg"}
  end

  defp avatar_dir(user), do: Uploads.disk_dir("avatars/#{user.id}")
  defp cover_dir(user), do: Uploads.disk_dir("covers/#{user.id}")

  defp dims(path) do
    {:ok, img} = Image.open(path)
    {Image.width(img), Image.height(img)}
  end

  # The single served cover version on disk. Its name embeds the handle and the
  # content fingerprint (`<slug>-wide-<fp>.avif`, see Vutuv.Uploads), so match it
  # by shape rather than hardcoding the fingerprint.
  defp served_wide(user) do
    [path] = Path.wildcard(Path.join(cover_dir(user), "*-wide-*.avif"))
    path
  end

  test "a rolled-back update writes no avatar files and leaves the column unchanged" do
    user = insert_activated_user(first_name: "Ada")

    # Valid avatar, but the name is too long: the changeset fails validation
    # after the avatar is validated, so the update rolls back.
    attrs = %{"avatar" => jpeg_upload(), "first_name" => String.duplicate("a", 51)}

    assert {:error, %Ecto.Changeset{}} = Accounts.update_user(user, attrs)

    refute File.exists?(avatar_dir(user)),
           "no avatar files should be written when the update rolls back"

    assert Uploads.Originals.path("avatars/#{user.id}") == nil
    assert Repo.get!(User, user.id).avatar == nil
  end

  test "a successful update stores the avatar after commit and sets the column" do
    user = insert_activated_user(first_name: "Ada")

    assert {:ok, updated} =
             Accounts.update_user(user, %{"avatar" => jpeg_upload(), "headline" => "Hi"})

    assert updated.avatar == "selfie.jpg"
    assert Repo.get!(User, user.id).avatar == "selfie.jpg"
    assert File.ls!(avatar_dir(user)) != []
    assert Uploads.Originals.path("avatars/#{user.id}")
    assert updated.headline == "Hi"
  end

  test "an undecodable image is rejected in the changeset and writes nothing" do
    user = insert_activated_user(first_name: "Ada")

    src = Path.join(System.tmp_dir!(), "broken_#{System.unique_integer([:positive])}.jpg")
    File.write!(src, "this is not an image")
    on_exit(fn -> File.rm(src) end)
    bad = %Plug.Upload{filename: "broken.jpg", path: src, content_type: "image/jpeg"}

    assert {:error, changeset} = Accounts.update_user(user, %{"avatar" => bad})
    assert "is not a valid image" in errors_on(changeset).avatar

    refute File.exists?(avatar_dir(user))
    assert Repo.get!(User, user.id).avatar == nil
  end

  test "a chosen avatar crop is normalised and persisted alongside the file" do
    user = insert_activated_user(first_name: "Ada")

    assert {:ok, updated} =
             Accounts.update_user(user, %{
               "avatar" => jpeg_upload(),
               "avatar_crop" => "0.25,0,0.5,1"
             })

    assert updated.avatar_crop == "0.2500,0.0000,0.5000,1.0000"
    assert Repo.get!(User, user.id).avatar_crop == "0.2500,0.0000,0.5000,1.0000"
  end

  test "a malformed crop param never fails the upload; it stores as no crop" do
    user = insert_activated_user(first_name: "Ada")

    assert {:ok, updated} =
             Accounts.update_user(user, %{"avatar" => jpeg_upload(), "avatar_crop" => "garbage"})

    assert updated.avatar == "selfie.jpg"
    assert updated.avatar_crop == nil
  end

  test "re-cropping the same image moves the fingerprint; an identical re-upload keeps it" do
    user = insert_activated_user(first_name: "Ada")
    # Reuse one upload (the file on disk survives store), so the original bytes
    # are byte-identical across the three saves and the crop is the only variable.
    upload = jpeg_upload()

    assert {:ok, a} =
             Accounts.update_user(user, %{"avatar" => upload, "avatar_crop" => "0,0,0.5,0.5"})

    # Same original bytes, a different crop: the crop is folded into the content
    # fingerprint, so the immutable (no `?v=`) served URL changes and no stale
    # crop is served from a browser/CDN cache.
    assert {:ok, b} =
             Accounts.update_user(Repo.get!(User, user.id), %{
               "avatar" => upload,
               "avatar_crop" => "0.5,0.5,0.5,0.5"
             })

    assert a.avatar_fingerprint =~ ~r/\A[0-9a-f]{12}\z/
    refute a.avatar_fingerprint == b.avatar_fingerprint

    # Same original bytes AND the same crop: the fingerprint is stable, so the
    # URL stays cacheable across an identical re-upload.
    assert {:ok, c} =
             Accounts.update_user(Repo.get!(User, user.id), %{
               "avatar" => upload,
               "avatar_crop" => "0.5,0.5,0.5,0.5"
             })

    assert c.avatar_fingerprint == b.avatar_fingerprint
  end

  test "the cover crop reaches the pipeline: the derived banner has the cropped dimensions" do
    user = insert_activated_user(first_name: "Ada")

    # A 600x400 source; a wide band at y=30%..55% is a 600x100 region. The
    # cover's width_down(1600) never upscales a 600px-wide source, so the
    # derived wide version keeps the cropped 600x100 instead of the full 600x400.
    assert {:ok, updated} =
             Accounts.update_user(user, %{
               "cover_photo" => jpeg_upload("banner.jpg"),
               "cover_crop" => "0,0.3,1,0.25"
             })

    assert updated.cover_crop == "0.0000,0.3000,1.0000,0.2500"
    assert dims(served_wide(user)) == {600, 100}
  end

  test "regenerate re-applies the persisted cover crop from the kept original" do
    user = insert_activated_user(first_name: "Ada")

    assert {:ok, _} =
             Accounts.update_user(user, %{
               "cover_photo" => jpeg_upload("banner.jpg"),
               "cover_crop" => "0,0.3,1,0.25"
             })

    # Wipe the served version, then re-derive from the kept original. Without
    # the persisted crop the regen would un-crop back to 600x400.
    File.rm!(served_wide(user))
    assert :ok = Vutuv.Cover.regenerate(Repo.get!(User, user.id), force: true)

    assert dims(served_wide(user)) == {600, 100}
  end

  test "a rolled-back update writes no cover-photo files either" do
    user = insert_activated_user(first_name: "Ada")

    attrs = %{
      "cover_photo" => jpeg_upload("banner.jpg"),
      "first_name" => String.duplicate("a", 51)
    }

    assert {:error, %Ecto.Changeset{}} = Accounts.update_user(user, attrs)

    refute File.exists?(Uploads.disk_dir("covers/#{user.id}"))
    assert Uploads.Originals.path("covers/#{user.id}") == nil
    assert Repo.get!(User, user.id).cover_photo == nil
  end
end
