defmodule VutuvWeb.MastodonApi.MediaAttachmentsTest do
  @moduledoc """
  The photographs a Mastodon client is handed — issues #1626 and #1627.

  Two halves of one complaint: a photo post from another network arrived as text
  only, and a photo on a *restricted* vutuv post arrived as a broken image. Both
  because a status is read by the app while its pictures are fetched by the
  platform's image loader, which sends neither the session cookie nor the bearer
  token the API call beside it used.

  So every test here does the same two things: read the status through the API,
  then fetch the URL it names **on a bare conn**, the way that loader would.
  Asserting the URL alone would have passed all along.

  Calibrated against the un-fixed adapter: drop `remote_attachments/2` or the
  capability out of `Vutuv.MastodonApi.Presenter` and the matching test goes red.

  `async: false` because it drives the rate-limited API endpoints.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers

  alias Vutuv.Fediverse.RemoteImage
  alias Vutuv.Posts
  alias Vutuv.RemoteMedia
  alias Vutuv.Repo

  setup do
    Vutuv.RateLimiter.reset()

    tmp = Path.join(System.tmp_dir!(), "vutuv_media_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev = Application.fetch_env(:vutuv, :uploads_dir_prefix)
    Application.put_env(:vutuv, :uploads_dir_prefix, tmp)

    on_exit(fn ->
      File.rm_rf(tmp)

      case prev do
        {:ok, was} -> Application.put_env(:vutuv, :uploads_dir_prefix, was)
        :error -> Application.delete_env(:vutuv, :uploads_dir_prefix)
      end
    end)

    {:ok, tmp: tmp}
  end

  defp jpeg_bytes do
    {:ok, image} = Image.new(8, 8, color: [10, 20, 30])
    {:ok, bytes} = Image.write(image, :memory, suffix: ".jpg")
    bytes
  end

  # A photograph on a cached post, written straight to disk: what is under test
  # is whether the adapter names it, not how it got here.
  defp remote_picture(post, attrs \\ %{}) do
    row =
      Repo.insert!(
        struct(
          %RemoteImage{
            remote_post_id: post.id,
            source_uri: "https://social.example/media/#{System.unique_integer([:positive])}.jpg",
            position: 0,
            alt: "Ein Bild von woanders.",
            width: 800,
            height: 600,
            moderation: "approved"
          },
          attrs
        )
      )

    {:ok, %{file: file}} = RemoteMedia.store_post_image(jpeg_bytes(), row.id)
    Repo.update!(Ecto.Changeset.change(row, file: file))
  end

  defp local_photo_post(author, tmp, attrs) do
    src = Path.join(tmp, "src-#{System.unique_integer([:positive])}.jpg")
    {:ok, img} = Image.new(64, 64, color: [10, 200, 100])
    {:ok, _} = Image.write(img, src)
    {:ok, image} = Posts.create_pending_image(author, src, "photo.jpg")

    {:ok, post} =
      Posts.create_post(author, Map.merge(%{body: "Mit Foto", image_ids: [image.id]}, attrs))

    {post, image}
  end

  # The status as a client reads it, and then its picture as that client's image
  # loader fetches it — a bare conn, no cookie, no bearer.
  defp attachment(conn, path) do
    [attachment] =
      conn
      |> get(path)
      |> json_response(200)
      |> Map.fetch!("media_attachments")

    attachment
  end

  defp fetch(url) do
    %URI{path: path, query: query} = URI.parse(url)
    get(build_conn(), path <> if(query, do: "?" <> query, else: ""))
  end

  describe "a photo post from another network" do
    setup %{conn: conn} do
      reader = federating_member()
      post = cached_post(remote_account(), content_text: "Seht mal.")
      image = remote_picture(post)

      {:ok, conn: mastodon_conn(conn, mastodon_token(reader, ["read"])), post: post, image: image}
    end

    # Issue #1626: both remote heads built on `base_status/1`, which defaults
    # `media_attachments: []`, and neither filled it — so the same post showed
    # its picture in a browser and none in an app.
    test "carries its photograph, and that URL loads for the client", ctx do
      attachment = attachment(ctx.conn, "/api/v1/statuses/remote-#{ctx.post.id}")

      assert attachment["type"] == "image"
      assert attachment["description"] == "Ein Bild von woanders."
      assert attachment["meta"]["original"] == %{"width" => 800, "height" => 600}
      assert fetch(attachment["url"]).status == 200
    end

    # Mastodon's `remote_url` is the origin's own copy, which is the one thing
    # a client may legitimately fetch past our proxy.
    test "names the origin's own copy beside ours", ctx do
      attachment = attachment(ctx.conn, "/api/v1/statuses/remote-#{ctx.post.id}")

      assert attachment["remote_url"] == ctx.image.source_uri
      refute attachment["url"] == ctx.image.source_uri
    end

    test "the same photograph reaches the timeline", ctx do
      [status] = ctx.conn |> get("/api/v1/timelines/public?remote=true") |> json_response(200)

      assert [%{"url" => url}] = status["media_attachments"]
      assert fetch(url).status == 200
    end

    test "a picture the AI gate has not cleared is not named at all", ctx do
      Repo.update!(Ecto.Changeset.change(ctx.image, moderation: "pending"))

      status = ctx.conn |> get("/api/v1/statuses/remote-#{ctx.post.id}") |> json_response(200)

      assert status["media_attachments"] == []
    end
  end

  # A cached *reply* carries no pictures anywhere in this codebase — there is no
  # note-image table and the inbox stores none. Pinned so the empty list reads as
  # the answer it is rather than as the gap #1626 described.
  describe "a cached reply from another network" do
    test "names no photograph, because none is ever stored for one", %{conn: conn} do
      author = federating_member()
      {:ok, post} = Posts.create_post(author, %{body: "Die Wurzel"})
      note = insert(:note, post: post)

      conn = mastodon_conn(conn, mastodon_token(insert(:activated_user), ["read"]))
      status = conn |> get("/api/v1/statuses/remote-note-#{note.id}") |> json_response(200)

      assert status["media_attachments"] == []
    end
  end

  describe "a photo on a restricted vutuv post" do
    setup %{conn: conn, tmp: tmp} do
      author = insert(:activated_user)
      reader = insert(:activated_user)
      follow!(reader, author)

      {post, image} =
        local_photo_post(author, tmp, %{denials: [%{"wildcard" => "non_followers"}]})

      {:ok,
       conn: mastodon_conn(conn, mastodon_token(reader, ["read"])),
       author: author,
       reader: reader,
       post: post,
       image: image}
    end

    # Issue #1627: the URL was named all along and answered 404, because the
    # loader is a nil viewer and `visible_to?/2` is false for a post carrying a
    # denial.
    test "loads for the reader the status was rendered for", ctx do
      attachment = attachment(ctx.conn, "/api/v1/statuses/#{ctx.post.id}")

      assert fetch(attachment["url"]).status == 200
      assert fetch(attachment["preview_url"]).status == 200
    end

    # What keeps the capability from being a key to the file: it names a member,
    # and the audience is asked again of that member per request.
    test "and stops loading once that reader leaves the audience", ctx do
      attachment = attachment(ctx.conn, "/api/v1/statuses/#{ctx.post.id}")

      Repo.delete_all(
        from(f in Vutuv.Social.Follow,
          where: f.follower_id == ^ctx.reader.id and f.followee_id == ^ctx.author.id
        )
      )

      assert fetch(attachment["url"]).status == 404
    end

    # The plain URL is what the old adapter named, and it is still what a bare
    # loader brings when it has no capability.
    test "the bare URL alone is still refused", ctx do
      assert fetch("/post_images/#{ctx.image.token}/large.avif").status == 404
    end
  end

  describe "a photo on a public vutuv post" do
    setup %{conn: conn, tmp: tmp} do
      author = insert(:activated_user)
      {post, image} = local_photo_post(author, tmp, %{})

      {:ok,
       conn: mastodon_conn(conn, mastodon_token(insert(:activated_user), ["read"])),
       post: post,
       image: image}
    end

    # A public photo needs no credential, so it is not given one: a bearer URL
    # that buys nothing is one more thing that can be shared.
    test "is named without a capability and loads anyway", ctx do
      attachment = attachment(ctx.conn, "/api/v1/statuses/#{ctx.post.id}")

      assert URI.parse(attachment["url"]).query == nil
      assert fetch(attachment["url"]).status == 200
    end
  end
end
