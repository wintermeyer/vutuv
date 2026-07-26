defmodule Vutuv.Posts.PhotoPostsTest do
  @moduledoc """
  Photo posts at the context level (issue #1104): the per-post license and its
  memory on the account, and the per-photo settings — including the two guards
  that keep the download promise from being quietly broken.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Posts
  alias Vutuv.Posts.PhotoLicense
  alias Vutuv.Posts.PostImage
  alias Vutuv.Repo

  defp author, do: insert(:user)

  defp photo_post(user, attrs \\ %{}) do
    image = insert(:post_image, user: user)

    {:ok, post} =
      Posts.create_post(
        user,
        Map.merge(%{body: "Lisbon, last morning", image_ids: [image.id]}, attrs)
      )

    {post, image}
  end

  describe "the license" do
    test "defaults to all rights reserved" do
      {post, _image} = photo_post(author())

      assert post.license == "arr"
      refute PhotoLicense.grants_reuse?(post.license)
    end

    test "is stored when the composer sends one" do
      {post, _image} = photo_post(author(), %{license: "cc-by-4.0"})

      assert post.license == "cc-by-4.0"
      assert PhotoLicense.grants_reuse?(post.license)
    end

    test "a tampered value falls back to the default rather than failing the post" do
      {post, _image} = photo_post(author(), %{license: "do-whatever-you-like"})

      assert post.license == "arr"
    end

    test "becomes the author's pre-selection for the next photo post" do
      user = author()
      assert Posts.default_license(user) == "arr"

      {_post, _image} = photo_post(user, %{license: "cc-by-sa-4.0"})

      assert user.id |> reload_user() |> Posts.default_license() == "cc-by-sa-4.0"
    end

    test "a text-only post never overwrites that standing pick" do
      user = author()
      {_post, _image} = photo_post(user, %{license: "cc0-1.0"})

      {:ok, _text_post} = Posts.create_post(reload_user(user.id), %{body: "Just a sentence."})

      assert user.id |> reload_user() |> Posts.default_license() == "cc0-1.0"
    end

    test "an edit that only changes the body leaves the license alone" do
      {post, image} = photo_post(author(), %{license: "cc-by-nc-4.0"})

      {:ok, updated} = Posts.update_post(post, %{body: "Fixed a typo", image_ids: [image.id]})

      assert updated.license == "cc-by-nc-4.0"
    end

    defp reload_user(id), do: Repo.get(Vutuv.Accounts.User, id)
  end

  describe "update_image_settings/2" do
    test "writes the caption, the alt text and the two opt-ins" do
      image = insert(:post_image, user: author())

      {:ok, updated} =
        Posts.update_image_settings(image, %{
          "alt" => "  A tram climbing a steep street  ",
          "caption" => "Lisbon, last morning",
          "show_camera_info" => true,
          "download_original" => true,
          "download_exact" => true
        })

      assert updated.alt == "A tram climbing a steep street"
      assert updated.caption == "Lisbon, last morning"
      assert updated.show_camera_info
      assert updated.download_original
      assert updated.download_exact
    end

    test "switching the download off also drops the exact-file choice" do
      image = insert(:post_image, user: author(), download_original: true, download_exact: true)

      {:ok, updated} =
        Posts.update_image_settings(image, %{
          "download_original" => false,
          "download_exact" => true
        })

      refute updated.download_original
      # The point: turning the download back on later must start from the safe
      # answer, not silently restore "hand out everything".
      refute updated.download_exact
    end

    test "a caption longer than the column is rejected, not truncated by Postgres" do
      image = insert(:post_image, user: author())
      too_long = String.duplicate("x", PostImage.max_caption_length() + 1)

      assert {:error, changeset} = Posts.update_image_settings(image, %{"caption" => too_long})
      assert %{caption: [_message]} = errors_on(changeset)
    end
  end

  describe "camera facts" do
    test "summarise into the line the panel and the lightbox share" do
      image =
        build(:post_image,
          camera: "Canon EOS R6",
          lens: "RF50mm F1.8 STM",
          focal_length: "50",
          aperture: "1.8",
          shutter: "1/200",
          iso: 400
        )

      assert PostImage.camera_summary(image) ==
               "Canon EOS R6 · RF50mm F1.8 STM · 50 mm · f/1.8 · 1/200 s · ISO 400"

      assert PostImage.camera_info?(image)
    end

    test "a photo with no camera facts cannot show a panel even if the flag is on" do
      image = build(:post_image, show_camera_info: true)

      refute PostImage.camera_info?(image)
      refute PostImage.show_camera_info?(image)
    end

    test "the panel needs both the facts and the author's consent" do
      facts = [camera: "Leica M11", iso: 200]

      refute PostImage.show_camera_info?(build(:post_image, facts))
      assert PostImage.show_camera_info?(build(:post_image, facts ++ [show_camera_info: true]))
    end
  end

  describe "download_url/1" do
    test "is nil until the author opens the download" do
      assert PostImage.download_url(build(:post_image)) == nil
    end

    test "does not reveal the stored file format" do
      image = build(:post_image, download_original: true, token: "abc123")

      url = PostImage.download_url(image)

      assert url == "/post_images/abc123/original.orig"
      refute String.contains?(url, "jpg")
    end
  end
end
