defmodule Vutuv.UploadsIntegrationTest do
  @moduledoc """
  End-to-end checks that the schemas store avatar/screenshot file names as plain
  strings and that legacy values (written by the old Waffle.Ecto type, which
  appended `?<gregorian_seconds>`) keep resolving to the right URLs.
  """
  # Not async: sets the global `:uploads_dir_prefix` application env.
  use Vutuv.DataCase, async: false

  import Vutuv.Factory

  alias Vutuv.Accounts.User
  alias Vutuv.Profiles.Url
  alias Vutuv.Repo
  alias VutuvWeb.Api.VCardJSON

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_uploads_int_#{System.unique_integer([:positive])}")
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

  test "a legacy avatar value with a ?timestamp suffix still resolves", %{} do
    # Simulate a row written by the old Waffle.Ecto type.
    user = insert(:user, avatar: "selfie.jpg?63876543210", first_name: "Ada", last_name: "King")
    reloaded = Repo.get!(User, user.id)

    # The column is now a plain string, returned verbatim.
    assert reloaded.avatar == "selfie.jpg?63876543210"

    # ...and the URL ignores the legacy timestamp, keeping the original extension.
    assert Vutuv.Avatar.url({reloaded.avatar, reloaded}, :thumb) ==
             "/avatars/#{user.id}/Ada%20King_thumb.jpg"
  end

  test "uploading an avatar stores the file name and writes files to disk", %{tmp: tmp} do
    user = insert(:user, first_name: "Ada", last_name: "King")
    upload = %Plug.Upload{filename: "me.png", path: png_fixture(), content_type: "image/png"}

    assert {:ok, updated} =
             user
             |> User.changeset(%{avatar: upload})
             |> Repo.update()

    assert updated.avatar == "me.png"
    assert File.exists?(Path.join(tmp, "avatars/#{user.id}/Ada King_thumb.png"))
  end

  test "an invalid avatar extension is rejected with a changeset error" do
    user = insert(:user)
    upload = %Plug.Upload{filename: "evil.gif", path: png_fixture(), content_type: "image/gif"}

    assert {:error, changeset} =
             user
             |> User.changeset(%{avatar: upload})
             |> Repo.update()

    assert "is not a valid image" in errors_on(changeset).avatar
  end

  test "uploading a cover photo stores the file name and writes files to disk", %{tmp: tmp} do
    user = insert(:user, first_name: "Ada", last_name: "King")
    upload = %Plug.Upload{filename: "banner.png", path: png_fixture(), content_type: "image/png"}

    assert {:ok, updated} =
             user
             |> User.changeset(%{cover_photo: upload})
             |> Repo.update()

    assert updated.cover_photo == "banner.png"
    assert File.exists?(Path.join(tmp, "covers/#{user.id}/Ada King_wide.png"))
  end

  test "an invalid cover photo extension is rejected with a changeset error" do
    user = insert(:user)
    upload = %Plug.Upload{filename: "evil.gif", path: png_fixture(), content_type: "image/gif"}

    assert {:error, changeset} =
             user
             |> User.changeset(%{cover_photo: upload})
             |> Repo.update()

    assert "is not a valid image" in errors_on(changeset).cover_photo
  end

  test "a legacy screenshot value resolves and uploads store a fingerprint", %{tmp: tmp} do
    user = insert(:user)
    legacy = insert(:url, user: user, screenshot: "shot.png?63876543210")
    assert Repo.get!(Url, legacy.id).screenshot == "shot.png?63876543210"

    assert Vutuv.Screenshot.url({legacy.screenshot, legacy}, :thumb) ==
             "/screenshots/#{legacy.id}/thumb-shot.webp"

    fresh = insert(:url, user: user)
    upload = %Plug.Upload{filename: "shot.png", path: png_fixture(), content_type: "image/png"}

    assert {:ok, updated} =
             fresh
             |> Url.changeset(%{screenshot: upload})
             |> Repo.update()

    assert updated.screenshot =~ ~r/^[0-9a-f]{12}\.png$/
    hash = Path.rootname(updated.screenshot)
    assert File.exists?(Path.join(tmp, "screenshots/#{fresh.id}/thumb-#{hash}.webp"))
  end

  test "the vCard embeds a real avatar as a JPEG PHOTO line", %{tmp: tmp} do
    user = insert(:user, first_name: "Ada", last_name: "King", avatar: "me.jpg")
    dir = Path.join(tmp, "avatars/#{user.id}")
    File.mkdir_p!(dir)
    {:ok, img} = Image.new(50, 50, color: [10, 120, 200])
    {:ok, _} = Image.write(img, Path.join(dir, "Ada King_thumb.jpg"))

    vcf = render_vcard(user)

    assert vcf =~ "PHOTO;ENCODING=b;TYPE=JPEG:"
    # The raw data: URI must not leak into the vCard.
    refute vcf =~ "data:image"
  end

  test "the vCard omits the PHOTO line when the user has no avatar" do
    user = insert(:user)
    vcf = render_vcard(user)

    refute vcf =~ "PHOTO"
  end

  defp render_vcard(user) do
    user
    |> Repo.preload([:addresses, :phone_numbers, :social_media_accounts, :emails])
    |> VCardJSON.vcard()
  end

  defp png_fixture do
    {:ok, img} = Image.new(300, 200, color: [10, 120, 200])
    path = Path.join(System.tmp_dir!(), "fixture_#{System.unique_integer([:positive])}.png")
    {:ok, _} = Image.write(img, path)
    path
  end
end
