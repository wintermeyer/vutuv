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
  alias VutuvWeb.AgentDocs.ProfileDoc
  alias VutuvWeb.AgentDocs.VCard

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

  test "a legacy avatar value with a ?timestamp suffix still resolves", %{tmp: tmp} do
    # Simulate a row written by the old Waffle.Ecto type, whose derived file
    # is still the pre-AVIF .jpg on disk.
    user = insert(:user, avatar: "selfie.jpg?63876543210", first_name: "Ada", last_name: "King")
    dir = Path.join(tmp, "avatars/#{user.id}")
    File.mkdir_p!(dir)
    {:ok, img} = Image.new(20, 20, color: [1, 2, 3])
    {:ok, _} = Image.write(img, Path.join(dir, "Ada King_thumb.jpg"))

    reloaded = Repo.get!(User, user.id)

    # The column is now a plain string, returned verbatim.
    assert reloaded.avatar == "selfie.jpg?63876543210"

    # ...and the URL ignores the legacy timestamp, falling back to the
    # not-yet-regenerated legacy file.
    assert Vutuv.Avatar.url({reloaded.avatar, reloaded}, :thumb) ==
             "/avatars/#{user.id}/Ada%20King_thumb.jpg"
  end

  test "uploading an avatar stores the file name and writes files to disk", %{tmp: tmp} do
    user = insert(:user, first_name: "Ada", last_name: "King")
    upload = %Plug.Upload{filename: "me.png", path: png_fixture(), content_type: "image/png"}

    # The file is written by Accounts.update_user/2 only after the row commits
    # (issue #776), not during changeset construction.
    assert {:ok, updated} = Vutuv.Accounts.update_user(user, %{avatar: upload})

    assert updated.avatar == "me.png"
    assert File.exists?(Path.join(tmp, "avatars/#{user.id}/avatar_thumb.avif"))
    assert File.exists?(Path.join(tmp, "originals/avatars/#{user.id}/original.png"))
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

    # Written by Accounts.update_user/2 after the row commits (issue #776).
    assert {:ok, updated} = Vutuv.Accounts.update_user(user, %{cover_photo: upload})

    assert updated.cover_photo == "banner.png"
    assert File.exists?(Path.join(tmp, "covers/#{user.id}/cover_wide.avif"))
    assert File.exists?(Path.join(tmp, "originals/covers/#{user.id}/original.png"))
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
    dir = Path.join(tmp, "screenshots/#{legacy.id}")
    File.mkdir_p!(dir)
    {:ok, img} = Image.new(20, 20, color: [1, 2, 3])
    {:ok, _} = Image.write(img, Path.join(dir, "thumb-shot.webp"))

    assert Repo.get!(Url, legacy.id).screenshot == "shot.png?63876543210"

    # The not-yet-regenerated legacy .webp thumb keeps resolving.
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
    assert File.exists?(Path.join(tmp, "screenshots/#{fresh.id}/thumb-#{hash}.avif"))
    assert File.exists?(Path.join(tmp, "originals/screenshots/#{fresh.id}/original.png"))
  end

  test "the vCard embeds a real avatar as a JPEG PHOTO line", %{tmp: tmp} do
    user = insert(:user, first_name: "Ada", last_name: "King", avatar: "me.jpg")
    dir = Path.join(tmp, "originals/avatars/#{user.id}")
    File.mkdir_p!(dir)
    {:ok, img} = Image.new(300, 200, color: [10, 120, 200])
    {:ok, _} = Image.write(img, Path.join(dir, "original.jpg"))

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
    |> ProfileDoc.build(include_photo: true)
    |> VCard.render()
  end

  defp png_fixture do
    {:ok, img} = Image.new(300, 200, color: [10, 120, 200])
    path = Path.join(System.tmp_dir!(), "fixture_#{System.unique_integer([:positive])}.png")
    {:ok, _} = Image.write(img, path)
    path
  end
end
