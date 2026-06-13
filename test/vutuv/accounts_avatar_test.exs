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
    tmp = Path.join(System.tmp_dir!(), "vutuv_accounts_avatar_#{System.unique_integer([:positive])}")
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

  test "a rolled-back update writes no cover-photo files either" do
    user = insert_activated_user(first_name: "Ada")

    attrs = %{"cover_photo" => jpeg_upload("banner.jpg"), "first_name" => String.duplicate("a", 51)}

    assert {:error, %Ecto.Changeset{}} = Accounts.update_user(user, attrs)

    refute File.exists?(Uploads.disk_dir("covers/#{user.id}"))
    assert Uploads.Originals.path("covers/#{user.id}") == nil
    assert Repo.get!(User, user.id).cover_photo == nil
  end
end
