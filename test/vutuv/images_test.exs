defmodule Vutuv.ImagesTest do
  @moduledoc """
  The shared `images` table, expand half (issue #2013).

  Two things have to be true at once. A profile picture and a cover are rows
  now — and **nothing has been taken away**: the member row keeps its four
  columns per kind filled, and no avatar or cover URL moves, because other
  servers hold those URLs in their copy of our ActivityPub actor document and
  sent mail holds them too.
  """
  # Not async: flips the global :uploads_dir_prefix and :moderate_images.
  use Vutuv.DataCase, async: false

  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Images
  alias Vutuv.Images.Image, as: ImageRow
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Repo

  @safe {:ok, %{safe?: true, category: "safe"}}
  @unsafe {:ok, %{safe?: false, category: "nudity"}}

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_images_test_#{System.unique_integer([:positive])}")
    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    user = insert(:activated_user)
    insert(:email, user: user)

    {:ok, user: user}
  end

  defp jpeg_upload(name \\ "selfie.jpg", color \\ [10, 120, 200]) do
    src = Path.join(System.tmp_dir!(), "images_src_#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(300, 200, color: color)
    {:ok, _} = Image.write(img, src)
    on_exit(fn -> File.rm(src) end)
    %Plug.Upload{filename: name, path: src, content_type: "image/jpeg"}
  end

  defp reload(user), do: Repo.get!(User, user.id)

  describe "an upload writes the row beside the member's own columns" do
    test "avatar", %{user: user} do
      {:ok, user} = Accounts.update_user(user, %{avatar: jpeg_upload()})

      # Nothing was taken away.
      assert user.avatar == "selfie.jpg"
      assert user.avatar_fingerprint
      assert user.avatar_moderation == "approved"

      image = Images.profile_image(user.id, "avatar")
      assert image.kind == "avatar"
      assert image.user_id == user.id
      assert image.file == user.avatar
      assert image.fingerprint == user.avatar_fingerprint
      assert image.moderation == user.avatar_moderation
      assert image.crop == user.avatar_crop
      assert is_binary(image.token) and image.token != ""
      assert image.frozen_at == nil

      assert reload(user).avatar_image_id == image.id
    end

    test "cover, with the member's crop", %{user: user} do
      {:ok, user} =
        Accounts.update_user(user, %{
          "cover_photo" => jpeg_upload("wide.jpg"),
          "cover_crop" => "0,0,0.5,0.5"
        })

      assert user.cover_photo == "wide.jpg"
      # Normalised on the way in (Vutuv.Uploads.Crop), so read it back rather
      # than repeating the literal the form sent.
      assert user.cover_crop == "0.0000,0.0000,0.5000,0.5000"

      image = Images.profile_image(user.id, "cover")
      assert image.kind == "cover"
      assert image.file == user.cover_photo
      assert image.crop == user.cover_crop
      assert image.fingerprint == user.cover_fingerprint
      assert reload(user).cover_image_id == image.id
    end

    test "the two kinds get one row each and two different tokens", %{user: user} do
      {:ok, user} =
        Accounts.update_user(user, %{
          avatar: jpeg_upload("a.jpg"),
          cover_photo: jpeg_upload("c.jpg", [200, 30, 30])
        })

      avatar = Images.profile_image(user.id, "avatar")
      cover = Images.profile_image(user.id, "cover")

      assert avatar.token != cover.token
      assert Repo.aggregate(ImageRow, :count) == 2
    end

    test "a re-upload replaces the one row and mints a fresh token", %{user: user} do
      {:ok, user} = Accounts.update_user(user, %{avatar: jpeg_upload("first.jpg")})
      first = Images.profile_image(user.id, "avatar")

      {:ok, user} = Accounts.update_user(user, %{avatar: jpeg_upload("second.jpg", [9, 9, 9])})
      second = Images.profile_image(user.id, "avatar")

      assert Repo.aggregate(from(i in ImageRow, where: i.user_id == ^user.id), :count) == 1
      assert second.id == first.id
      assert second.file == "second.jpg"
      assert second.fingerprint == user.avatar_fingerprint
      assert second.token != first.token
      assert reload(user).avatar_image_id == second.id
    end
  end

  describe "no URL moves" do
    test "the avatar and cover URLs are exactly the ones the member row builds", %{user: user} do
      {:ok, user} =
        Accounts.update_user(user, %{
          avatar: jpeg_upload("a.jpg"),
          cover_photo: jpeg_upload("c.jpg", [200, 30, 30])
        })

      # The one shape other servers, Google and sent mail already hold:
      # /avatars/<user id>/<handle>-<version>-<fingerprint>.avif — built from
      # the member row's own columns, with the images row playing no part.
      assert Vutuv.Avatar.url({user.avatar, user}, :medium) ==
               "/avatars/#{user.id}/#{user.username}-medium-#{user.avatar_fingerprint}.avif"

      assert Vutuv.Avatar.display_url(user, :thumb) ==
               "/avatars/#{user.id}/#{user.username}-thumb-#{user.avatar_fingerprint}.avif"

      assert Vutuv.Cover.url({user.cover_photo, user}, :wide) ==
               "/covers/#{user.id}/#{user.username}-wide-#{user.cover_fingerprint}.avif"
    end
  end

  describe "the AI gate's verdict reaches the row too" do
    setup do
      put_config(:moderate_images, true)
      :ok
    end

    test "a fresh upload is pending on both, and released on both", %{user: user} do
      {:ok, user} = Accounts.update_user(user, %{avatar: jpeg_upload()})

      assert user.avatar_moderation == "pending"
      assert Images.profile_image(user.id, "avatar").moderation == "pending"

      ImageScans.deliver_due(judge: fn _path -> @safe end)

      assert reload(user).avatar_moderation == "approved"
      assert Images.profile_image(user.id, "avatar").moderation == "approved"
    end

    test "a rejection clears the member's columns and drops the row", %{user: user} do
      {:ok, user} = Accounts.update_user(user, %{avatar: jpeg_upload()})
      assert Images.profile_image(user.id, "avatar")

      ImageScans.deliver_due(judge: fn _path -> @unsafe end)

      user = reload(user)
      assert user.avatar == nil
      assert user.avatar_moderation == nil
      assert user.avatar_image_id == nil
      assert Images.profile_image(user.id, "avatar") == nil
    end
  end

  describe "a re-derive keeps the row's fingerprint in step" do
    test "regenerating under a new handle leaves both sides naming the same bytes", %{user: user} do
      {:ok, user} = Accounts.update_user(user, %{avatar: jpeg_upload()})

      # Force a re-derive the way the deploy's regeneration pass does.
      assert :ok = Vutuv.Avatar.regenerate(user, force: true)

      user = reload(user)
      assert Images.profile_image(user.id, "avatar").fingerprint == user.avatar_fingerprint
    end
  end

  describe "how a kind is served is a property of the kind" do
    test "avatars and covers are served straight off disk" do
      assert Images.serving("avatar") == :static
      assert Images.serving("cover") == :static
      assert Images.kinds() == ~w(avatar cover)
    end

    test "an undeclared kind raises rather than inheriting a default" do
      assert_raise ArgumentError, ~r/no serving strategy declared/, fn ->
        Images.serving("post_image")
      end
    end
  end

  describe "the row's own guards" do
    test "a token is unique across the table", %{user: user} do
      other = insert(:activated_user)
      {:ok, user} = Accounts.update_user(user, %{avatar: jpeg_upload()})
      taken = Images.profile_image(user.id, "avatar").token

      assert {:error, changeset} =
               %ImageRow{}
               |> ImageRow.changeset(%{
                 "kind" => "avatar",
                 "user_id" => other.id,
                 "token" => taken
               })
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).token
    end

    test "a profile kind without an owner is refused by the database" do
      assert {:error, changeset} =
               %ImageRow{}
               |> ImageRow.changeset(%{"kind" => "avatar", "token" => Vutuv.Uploads.gen_token()})
               |> Repo.insert()

      assert errors_on(changeset)[:user_id]
    end

    test "an over-long file name is refused rather than raising 22001" do
      changeset =
        ImageRow.changeset(%ImageRow{}, %{
          "kind" => "avatar",
          "token" => "t",
          "file" => String.duplicate("a", 256)
        })

      assert errors_on(changeset)[:file]
    end
  end
end
