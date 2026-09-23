defmodule Vutuv.FediverseVideoNoteTest do
  @moduledoc """
  A post with a clip federates as a playable attachment (issue #1913): one
  `Document` of type `video/mp4` naming the H.264 file, with its size, length,
  description and cover — and the photo attachments now carry their
  description and size too.
  """

  use Vutuv.DataCase

  import Vutuv.WebPushHelpers, only: [put_config: 2]

  alias Vutuv.Posts
  alias Vutuv.Posts.PostImage
  alias Vutuv.Repo
  alias Vutuv.VideoFixtures
  alias Vutuv.Videos
  alias Vutuv.Videos.Job
  alias VutuvWeb.Fediverse.Docs

  setup do
    tmp = Path.join(System.tmp_dir!(), "vutuv_video_note_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    put_config(:uploads_dir_prefix, tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    %{user: insert_activated_user(fediverse_followers?: true, admin?: true)}
  end

  test "the Note carries the clip as a video/mp4 Document with icon and duration", %{user: user} do
    path = VideoFixtures.mp4_path()
    {:ok, video} = Videos.create_pending_video(user, path, Path.basename(path))
    :ok = Job.run(video.id)
    {:ok, _} = Videos.update_alt(Videos.get_video(video.id), "A short talk")

    {:ok, post} = Posts.create_post(user, %{body: "Watch", video_id: video.id})
    note = post |> Repo.preload(Docs.note_preloads()) |> Docs.note(user)

    assert [attachment] = note["attachment"]
    assert attachment["type"] == "Document"
    assert attachment["mediaType"] == "video/mp4"
    assert attachment["url"] =~ "/post_videos/#{video.token}/h264.mp4"
    assert attachment["name"] == "A short talk"
    assert attachment["width"] == 320
    assert attachment["height"] == 180
    assert attachment["duration"] == "PT3S"
    assert %{"type" => "Image", "mediaType" => "image/jpeg", "url" => icon} = attachment["icon"]
    assert icon =~ "/post_videos/#{video.token}/cover.jpg"
  end

  test "a photo attachment names its description and size", %{user: user} do
    image = insert(:post_image, user: user, alt: "A bridge", width: 640, height: 480)
    {:ok, post} = Posts.create_post(user, %{body: "Look", image_ids: [image.id]})
    note = post |> Repo.preload(Docs.note_preloads()) |> Docs.note(user)

    assert [%{"mediaType" => "image/jpeg", "name" => "A bridge", "width" => 640, "height" => 480}] =
             note["attachment"]
  end

  # Mastodon refuses AVIF (issue #2279): it downloads the file, rejects the
  # type and shows an empty frame. The attachment names the JPEG, at the size
  # that JPEG is served in.
  test "a photo federates as the link-preview JPEG, at its size", %{user: user} do
    image = insert(:post_image, user: user, width: 2400, height: 1200)
    {:ok, post} = Posts.create_post(user, %{body: "Wide", image_ids: [image.id]})
    note = post |> Repo.preload(Docs.note_preloads()) |> Docs.note(user)

    assert [%{"url" => url, "width" => 1200, "height" => 600}] = note["attachment"]
    assert url =~ "/post_images/#{image.token}/og.jpg"
  end

  # The switch back (`@federated_photo_format` in `Docs`) waits for Mastodon to
  # take AVIF again; this keeps that branch naming a file we really serve.
  test "the AVIF branch names the large version at the photo's own size", %{user: user} do
    image = insert(:post_image, user: user, width: 2400, height: 1200)

    assert {"image/avif", url, 2400, 1200} = Docs.photo_file(:avif, image)
    assert url == PostImage.url(image, "large")
  end

  # What Mastodon's `MediaAttachment` accepts from a remote server today; any
  # other type is downloaded, refused and shown as an empty frame.
  @mastodon_media_types ~w(image/jpeg image/png image/gif image/webp video/mp4)

  test "every attachment is a type Mastodon accepts", %{user: user} do
    path = VideoFixtures.mp4_path()
    {:ok, video} = Videos.create_pending_video(user, path, Path.basename(path))
    :ok = Job.run(video.id)
    image = insert(:post_image, user: user, width: 640, height: 480)

    {:ok, post} =
      Posts.create_post(user, %{body: "Both", video_id: video.id, image_ids: [image.id]})

    note = post |> Repo.preload(Docs.note_preloads()) |> Docs.note(user)

    assert [_, _] = note["attachment"]

    for attachment <- note["attachment"] do
      assert attachment["mediaType"] in @mastodon_media_types
    end
  end
end
