defmodule Vutuv.FediverseMediaTest do
  @moduledoc """
  Pictures from the accounts a member follows (issue #1163): what is recorded,
  what is fetched, what the AI gate holds back, and that nothing is left at
  rest once the row it hangs off is gone.

  `async: false` — the HTTP stub and the image-moderation switch live in the
  application env, which the SQL sandbox does not roll back.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.Media
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemoteImage
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Moderation.ImageScan
  alias Vutuv.Moderation.ImageSubjects
  alias Vutuv.RemoteMedia

  @actor "https://social.example/users/them"
  @picture "https://social.example/media/1.jpg"

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  # A real, decodable JPEG — the store runs libvips over it, so a fake binary
  # would only ever exercise the error path.
  defp jpeg_bytes do
    {:ok, image} = Image.new(64, 64, color: [40, 90, 160])
    {:ok, bytes} = Image.write(image, :memory, suffix: ".jpg")
    bytes
  end

  defp stub_download(fun) do
    Application.put_env(:vutuv, :fediverse_req_options, plug: fun)
    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
  end

  defp serving_bytes(bytes) do
    stub_download(fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, bytes)
    end)
  end

  defp account do
    Repo.insert!(%RemoteAccount{
      actor_uri: @actor,
      host: "social.example",
      handle: "them",
      inbox_uri: @actor <> "/inbox"
    })
  end

  defp cached_post(acc, attrs \\ %{}) do
    now = DateTime.utc_now(:second)

    Repo.insert!(
      struct(
        %RemotePost{
          remote_account_id: acc.id,
          object_uri: "https://social.example/posts/#{System.unique_integer([:positive])}",
          content_text: "Mit Bild.",
          audience: "public",
          kind: "note",
          published_at: now,
          received_at: now,
          expires_at: DateTime.add(now, 86_400)
        },
        attrs
      )
    )
  end

  defp attachment(url \\ @picture, type \\ "image/jpeg"),
    do: %{"type" => "Document", "mediaType" => type, "url" => url, "name" => "Ein Zug"}

  # The test env ships with AI image moderation off, so a stored picture is born
  # `approved`. Anything about the gate has to turn it on, or it is testing the
  # installation-without-Ollama path instead.
  defp with_moderation do
    # Restored, not deleted: `config/test.exs` sets this to false and
    # `Application.delete_env/2` would drop that, leaving the default `true`
    # behind for every test that runs after this module — which holds their
    # post images in AI limbo and 404s them. (Caught by the full suite; each
    # file passed on its own.)
    previous = Application.get_env(:vutuv, :moderate_images)
    Application.put_env(:vutuv, :moderate_images, true)
    on_exit(fn -> Application.put_env(:vutuv, :moderate_images, previous) end)
  end

  describe "what is recorded" do
    test "keeps up to four pictures, in order, with their alt text" do
      post = cached_post(account())

      attachments =
        for n <- 1..6, do: attachment("https://social.example/media/#{n}.jpg")

      images = Media.record_attachments(post, attachments, false)

      assert length(images) == RemoteImage.max_per_post()
      assert Enum.map(images, & &1.position) == [0, 1, 2, 3]
      assert Enum.all?(images, &(&1.alt == "Ein Zug"))
    end

    test "an audio file or an undeclared file is not a picture; a video is recorded (issue #1914)" do
      post = cached_post(account())

      attachments = [
        attachment("https://social.example/media/clip.mp4", "video/mp4"),
        attachment("https://social.example/media/talk.mp3", "audio/mpeg"),
        %{"url" => "https://social.example/media/x.jpg"}
      ]

      assert [%RemoteImage{media_type: "video/mp4", poster_uri: nil, file: nil} = clip] =
               Media.record_attachments(post, attachments, false)

      assert RemoteImage.video?(clip)
      # Nothing to fetch, nothing to judge: it plays as it is.
      assert RemoteImage.display_state(clip) == :ready
      assert Media.fetch_now(clip) == :skip
      assert Media.due_refetches() == []
    end

    test "a video's cover is what gets fetched and judged (issue #1914)" do
      post = cached_post(account())

      attachment =
        "https://social.example/media/clip.mp4"
        |> attachment("video/mp4")
        |> Map.put("icon", %{
          "type" => "Image",
          "mediaType" => "image/jpeg",
          "url" => "https://social.example/media/clip-cover.jpg"
        })

      assert [%RemoteImage{poster_uri: "https://social.example/media/clip-cover.jpg"} = clip] =
               Media.record_attachments(post, [attachment], false)

      assert RemoteImage.fetch_uri(clip) == "https://social.example/media/clip-cover.jpg"
      # With a cover named and none fetched yet, the card waits for the cover.
      assert RemoteImage.display_state(clip) == :waiting
    end

    # A reader about to tap a clip is spending their own data on somebody
    # else's server — 94 MB for 73 seconds, measured on social.bund.de — so the
    # card has to say how long it is before they tap. Every instance measured
    # (legal.social, social.bund.de, chaos.social) fills these in, including the
    # three quarters that send no cover at all, so they are worth reading.
    test "a clip's own length and size come out of the attachment (issue #1914)" do
      post = cached_post(account())

      attachment =
        "https://social.example/media/clip.mp4"
        |> attachment("video/mp4")
        |> Map.merge(%{"duration" => "PT1M13.2S", "width" => 1080, "height" => 1920})

      assert [clip] = Media.record_attachments(post, [attachment], false)

      assert clip.duration_ms == 73_200
      # The clip's own shape, not the cover's — `width`/`height` stay the
      # cover's, which is a thumbnail a fraction of this size.
      assert clip.video_width == 1080
      assert clip.video_height == 1920
      assert clip.width == nil
    end

    # The three quarters of clips that name no cover have nothing else to draw
    # (27 of 36 in one day's cached posts), so this is what keeps them from
    # rendering as a black box.
    test "a clip keeps the BlurHash its attachment carries" do
      post = cached_post(account())
      hash = "UKFrYAoN0hM{IVbIShRj9Gog%M%2-gj]N1%2"

      attachment =
        "https://social.example/media/clip.mp4"
        |> attachment("video/mp4")
        |> Map.put("blurhash", hash)

      assert [clip] = Media.record_attachments(post, [attachment], false)
      assert clip.blurhash == hash
    end

    # A hash that does not decode is worse than none: the card would carry a
    # string it cannot draw. The structural check is a real decode, so a
    # truncated hash — well-formed base83 to the last character — is caught.
    test "a BlurHash that does not decode is not kept" do
      post = cached_post(account())

      for bad <- ["UKFrYA", "nope", String.duplicate("A", 200)] do
        attachment =
          "https://social.example/media/clip-#{bad}.mp4"
          |> attachment("video/mp4")
          |> Map.put("blurhash", bad)

        assert [clip] = Media.record_attachments(post, [attachment], false)
        assert clip.blurhash == nil, "kept #{inspect(bad)}"
      end
    end

    test "a picture takes no length, whatever the attachment claims" do
      post = cached_post(account())
      attachment = Map.put(attachment(), "duration", "PT30S")

      assert [image] = Media.record_attachments(post, [attachment], false)
      assert image.duration_ms == nil
    end

    # The string is a remote server's, so every shape it is not must answer
    # `nil` rather than raise or invent a number.
    test "an unreadable duration is no duration" do
      for value <- ["", "PT", "nonsense", "P1D", "PT-5S", "PT99999999H", 42, nil, %{}] do
        assert Media.duration_ms(value) == nil, "expected nil for #{inspect(value)}"
      end

      assert Media.duration_ms("PT35.88S") == 35_880
      assert Media.duration_ms("PT1M30S") == 90_000
      assert Media.duration_ms("PT1H2M3S") == 3_723_000
    end

    test "the author's sensitive flag rides along" do
      post = cached_post(account())

      assert [image] = Media.record_attachments(post, [attachment()], true)
      assert RemoteImage.blurred?(image)
    end
  end

  describe "measuring a clip" do
    defp video_row(attrs \\ %{}) do
      post = cached_post(account())

      attachment =
        "https://social.example/media/clip.mp4"
        |> attachment("video/mp4")
        |> Map.merge(attrs)

      [clip] = Media.record_attachments(post, [attachment], false)
      clip
    end

    defp answering_head(headers) do
      stub_download(fn conn ->
        Enum.reduce(headers, conn, fn {k, v}, acc -> Plug.Conn.put_resp_header(acc, k, v) end)
        |> Plug.Conn.send_resp(200, "")
      end)
    end

    test "a HEAD says how many bytes a tap will cost" do
      answering_head([{"content-length", "94407457"}])
      clip = video_row()

      assert :ok = Media.measure_clip(clip)
      assert Repo.get!(RemoteImage, clip.id).byte_size == 94_407_457
    end

    # Plenty of servers answer a HEAD without one, and a card with a length but
    # no size is most of the warning already — so this must stay quiet rather
    # than becoming work somebody retries.
    test "no content-length leaves the size unknown and says nothing" do
      answering_head([])
      clip = video_row()

      assert :ok = Media.measure_clip(clip)
      assert Repo.get!(RemoteImage, clip.id).byte_size == nil
    end

    test "a picture is never measured" do
      answering_head([{"content-length", "4096"}])
      post = cached_post(account())
      [image] = Media.record_attachments(post, [attachment()], false)

      assert :ok = Media.measure_clip(image)
      assert Repo.get!(RemoteImage, image.id).byte_size == nil
    end
  end

  describe "fetching" do
    test "stores the bytes, records the file and hands it to the gate" do
      with_moderation()
      serving_bytes(jpeg_bytes())
      post = cached_post(account())
      [image] = Media.record_attachments(post, [attachment()], false)

      assert :ok = Media.fetch_now(image)

      stored = Repo.get!(RemoteImage, image.id)
      assert is_binary(stored.file)
      assert stored.width == 64 and stored.height == 64
      assert RemoteMedia.post_image_path(stored.id, Path.rootname(stored.file), stored.file)

      # Handed over, and bound to the exact bytes: a verdict can never release
      # a picture the model did not see.
      assert [scan] = Repo.all(from(s in ImageScan, where: s.kind == "remote_post_image"))
      assert scan.subject_id == image.id
      assert scan.fingerprint == stored.file
      assert scan.owner_user_id == nil
    end

    test "the bytes landing is announced, verdict or no verdict (issue #1927)" do
      # What every open card was missing. It was drawn a second ago, when this
      # row had no file and there was nothing to show; from here on there is the
      # mosaic preview standing in for the picture, and the gate's own
      # announcement is a median of 97 seconds away.
      with_moderation()
      serving_bytes(jpeg_bytes())
      post = cached_post(account())
      [image] = Media.record_attachments(post, [attachment()], false)
      Fediverse.subscribe_remote_images()

      assert :ok = Media.fetch_now(image)

      assert_receive {:remote_images_changed, %{remote_post_id: id}}
      assert id == post.id
      assert Repo.get!(RemoteImage, image.id).moderation == "pending"
    end

    test "a server that does not answer leaves the post readable" do
      stub_download(fn conn -> Plug.Conn.send_resp(conn, 500, "") end)
      post = cached_post(account())
      [image] = Media.record_attachments(post, [attachment()], false)

      assert :skip = Media.fetch_now(image)
      assert Repo.get!(RemoteImage, image.id).file == nil
      # The post itself is untouched — a missing picture is not a missing post.
      assert Repo.get!(RemotePost, post.id).content_text == "Mit Bild."
    end

    test "a file over the ceiling is never stored" do
      Application.put_env(:vutuv, :fediverse_media_max_bytes, 10)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_media_max_bytes) end)

      serving_bytes(jpeg_bytes())
      post = cached_post(account())
      [image] = Media.record_attachments(post, [attachment()], false)

      assert :skip = Media.fetch_now(image)
      assert Repo.get!(RemoteImage, image.id).file == nil
    end

    test "an avatar is fetched once and not again for the same URL" do
      serving_bytes(jpeg_bytes())
      acc = account()

      assert :ok = Media.fetch_avatar_now(acc, "https://social.example/avatars/1.png")

      stored = Repo.get!(RemoteAccount, acc.id)
      assert is_binary(stored.avatar)
      assert stored.avatar_source == "https://social.example/avatars/1.png"

      # A re-delivered actor document names the same picture; nothing is
      # downloaded again.
      assert :skip = Media.fetch_avatar_now(stored, "https://social.example/avatars/1.png")
    end
  end

  describe "the gate" do
    setup do
      with_moderation()
      serving_bytes(jpeg_bytes())
      post = cached_post(account())
      [image] = Media.record_attachments(post, [attachment()], false)
      :ok = Media.fetch_now(image)
      %{post: post, image: Repo.get!(RemoteImage, image.id)}
    end

    test "nothing renders before a verdict", %{post: post, image: image} do
      assert image.moderation == "pending"
      refute RemoteImage.released?(image)

      # The row is listed, so the card can say a picture is on its way rather
      # than render an empty post — but it is not released, which is the only
      # thing that lets bytes out (here and in the proxy).
      assert [waiting] = Map.get(Fediverse.list_remote_images([post.id]), post.id)
      refute RemoteImage.released?(waiting)
    end

    test "an approved picture renders", %{post: post, image: image} do
      scan = Repo.one!(from(s in ImageScan, where: s.kind == "remote_post_image"))
      assert :ok = ImageSubjects.apply_approved(scan)

      released = Repo.get!(RemoteImage, image.id)
      assert RemoteImage.released?(released)
      assert [shown] = Map.get(Fediverse.list_remote_images([post.id]), post.id)
      assert shown.id == image.id
    end

    test "a rejection deletes the file and the reference, and keeps the post", %{
      post: post,
      image: image
    } do
      scan = Repo.one!(from(s in ImageScan, where: s.kind == "remote_post_image"))

      assert :ok = ImageSubjects.apply_rejected(scan)

      cleared = Repo.get!(RemoteImage, image.id)
      assert cleared.file == nil
      refute RemoteImage.released?(cleared)
      refute RemoteMedia.post_image_path(image.id, "img", image.file)
      # The post survives its picture being refused.
      assert Repo.get(RemotePost, post.id)
    end
  end

  describe "who may see a picture" do
    setup do
      acc = account()
      user = insert(:activated_user, fediverse_followers?: true)
      %{account: acc, user: user}
    end

    defp follow(user, acc, state) do
      Repo.insert!(%Follow{
        user_id: user.id,
        remote_account_id: acc.id,
        state: state,
        follow_activity_id: "https://vutuv.test/#{user.id}/actor#follows/#{acc.id}"
      })
    end

    test "a picture is exactly as readable as its post", %{account: acc, user: user} do
      public = %RemoteImage{remote_post: cached_post(acc)}
      private = %RemoteImage{remote_post: cached_post(acc, %{audience: "followers"})}

      stranger = insert(:activated_user)
      follow(user, acc, "requested")

      assert Fediverse.remote_image_visible?(public, user)
      # A request nobody answered does not open the author's restricted posts.
      refute Fediverse.remote_image_visible?(private, user)
      # An open post is readable by any signed-in member, which is what the
      # account page already shows: a picture on it must not be stricter than
      # the text beside it. A boost or a repost reaches such a reader too.
      assert Fediverse.remote_image_visible?(public, stranger)
      refute Fediverse.remote_image_visible?(private, stranger)
    end
  end

  describe "what the feed carries" do
    test "a released picture rides its entry" do
      serving_bytes(jpeg_bytes())
      acc = account()
      post = cached_post(acc)
      [image] = Media.record_attachments(post, [attachment()], false)
      :ok = Media.fetch_now(image)

      user = insert(:activated_user, fediverse_followers?: true)
      follow(user, acc, "accepted")

      assert [entry] = Vutuv.Posts.feed_page(user).entries
      assert Vutuv.Posts.remote_feed_entry?(entry)
      assert [shown] = entry.images
      assert shown.id == image.id
    end

    test "a picture the gate has not cleared rides along unreleased" do
      with_moderation()
      serving_bytes(jpeg_bytes())
      acc = account()
      post = cached_post(acc)
      [image] = Media.record_attachments(post, [attachment()], false)
      :ok = Media.fetch_now(image)

      user = insert(:activated_user, fediverse_followers?: true)
      follow(user, acc, "accepted")

      assert [entry] = Vutuv.Posts.feed_page(user).entries
      assert entry.remote_post.id == post.id
      # Carried so the card can say a picture is on its way — the post is
      # readable meanwhile — but not released, which is the only thing that
      # lets the bytes out.
      assert [waiting] = entry.images
      refute RemoteImage.released?(waiting)
    end
  end

  describe "nothing is left at rest" do
    setup do
      serving_bytes(jpeg_bytes())
      acc = account()
      post = cached_post(acc)
      [image] = Media.record_attachments(post, [attachment()], false)
      :ok = Media.fetch_now(image)
      %{account: acc, post: post, image: Repo.get!(RemoteImage, image.id)}
    end

    test "expiry takes the files with the rows", %{image: image} do
      Repo.update_all(RemotePost, set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1)])

      assert Fediverse.expire_due_remote_posts() == 1
      assert Repo.aggregate(RemoteImage, :count) == 0
      refute RemoteMedia.post_image_path(image.id, Path.rootname(image.file), image.file)
    end

    test "an upstream Delete does too", %{post: post, image: image} do
      assert :ok = Fediverse.delete_remote_post(@actor, post.object_uri)

      assert Repo.aggregate(RemoteImage, :count) == 0
      refute RemoteMedia.post_image_path(image.id, Path.rootname(image.file), image.file)
    end

    test "the unfollow purge does too", %{image: image} do
      assert Fediverse.purge_unfollowed_remote_posts() == 1
      assert Repo.aggregate(RemoteImage, :count) == 0
      refute RemoteMedia.post_image_path(image.id, Path.rootname(image.file), image.file)
    end

    test "so does a member reporting the post", %{post: post, image: image} do
      # The reporter is told "our copy was deleted right away", so the bytes
      # have to be gone too, not just the row.
      assert :ok = Fediverse.report_remote_post(post.id, insert(:activated_user))

      assert Repo.aggregate(RemoteImage, :count) == 0
      refute RemoteMedia.post_image_path(image.id, Path.rootname(image.file), image.file)
    end

    test "so does the account deleting itself", %{account: acc, image: image} do
      serving_bytes(jpeg_bytes())
      :ok = Media.fetch_avatar_now(acc, "https://social.example/avatars/1.png")
      stored = Repo.get!(RemoteAccount, acc.id)

      assert :ok = Fediverse.remove_remote_account(@actor)

      assert Repo.aggregate(RemoteAccount, :count) == 0
      assert Repo.aggregate(RemoteImage, :count) == 0
      refute RemoteMedia.post_image_path(image.id, Path.rootname(image.file), image.file)
      refute RemoteMedia.avatar_path(acc.id, Path.rootname(stored.avatar), stored.avatar)
    end

    test "so does blocking the server", %{account: acc, image: image} do
      serving_bytes(jpeg_bytes())
      :ok = Media.fetch_avatar_now(acc, "https://social.example/avatars/1.png")
      stored = Repo.get!(RemoteAccount, acc.id)

      {:ok, {_blocked, purged}} =
        Fediverse.block_instance(%{"host" => "social.example"}, insert(:user, admin?: true))

      assert purged.cached_posts == 1
      assert Repo.aggregate(RemoteImage, :count) == 0
      refute RemoteMedia.post_image_path(image.id, Path.rootname(image.file), image.file)
      refute RemoteMedia.avatar_path(acc.id, Path.rootname(stored.avatar), stored.avatar)
    end
  end

  describe "an author's edit" do
    setup do
      acc = account()
      insert(:activated_user, fediverse_followers?: true)
      %{account: acc}
    end

    defp update_activity(post, object_attrs) do
      %{
        "type" => "Update",
        "actor" => @actor,
        "object" =>
          Map.merge(
            %{
              "id" => post.object_uri,
              "type" => "Note",
              "content" => "<p>Mit Bild.</p>",
              "to" => ["https://www.w3.org/ns/activitystreams#Public"]
            },
            object_attrs
          )
      }
    end

    test "a content warning added afterwards covers the pictures too", %{account: acc} do
      post = cached_post(acc)
      [image] = Media.record_attachments(post, [attachment()], false)
      refute RemoteImage.blurred?(image)

      :ok =
        Fediverse.update_remote_post(
          update_activity(post, %{"summary" => "Heikles Motiv", "attachment" => [attachment()]}),
          @actor
        )

      # The author asked for a cover; our copy has to honour it, not keep
      # showing the picture bare because the warning arrived a minute late.
      assert RemoteImage.blurred?(Repo.get!(RemoteImage, image.id))
    end

    test "a picture the author removed goes, with its file", %{account: acc} do
      serving_bytes(jpeg_bytes())
      post = cached_post(acc)
      [image] = Media.record_attachments(post, [attachment()], false)
      :ok = Media.fetch_now(image)
      stored = Repo.get!(RemoteImage, image.id)

      :ok = Fediverse.update_remote_post(update_activity(post, %{"attachment" => []}), @actor)

      assert Repo.aggregate(RemoteImage, :count) == 0
      refute RemoteMedia.post_image_path(stored.id, Path.rootname(stored.file), stored.file)
    end

    test "a picture added afterwards is recorded", %{account: acc} do
      post = cached_post(acc)
      assert Media.record_attachments(post, [], false) == []

      :ok =
        Fediverse.update_remote_post(
          update_activity(post, %{"attachment" => [attachment()]}),
          @actor
        )

      assert Repo.aggregate(RemoteImage, :count) == 1
    end

    test "editing a post that is only a picture does not delete it", %{account: acc} do
      post = cached_post(acc, %{content_text: ""})
      [_image] = Media.record_attachments(post, [attachment()], false)

      :ok =
        Fediverse.update_remote_post(
          update_activity(post, %{"content" => "", "attachment" => [attachment()]}),
          @actor
        )

      # Reading only the text used to read "the author emptied this" and delete
      # the post — on the very case this feature exists for.
      assert Repo.get(RemotePost, post.id)
    end
  end

  test "the two new scan kinds exist and carry no owner" do
    # Nobody here uploaded these, so a rejection notifies nobody: there is no
    # member whose content was removed.
    assert "remote_post_image" in ImageScan.kinds()
    assert "remote_avatar" in ImageScan.kinds()
  end
end
