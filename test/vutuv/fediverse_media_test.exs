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

    test "a video or an audio file is not a picture" do
      post = cached_post(account())

      attachments = [
        attachment("https://social.example/media/clip.mp4", "video/mp4"),
        attachment("https://social.example/media/talk.mp3", "audio/mpeg"),
        %{"url" => "https://social.example/media/x.jpg"}
      ]

      assert Media.record_attachments(post, attachments, false) == []
    end

    test "the author's sensitive flag rides along" do
      post = cached_post(account())

      assert [image] = Media.record_attachments(post, [attachment()], true)
      assert RemoteImage.blurred?(image)
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
