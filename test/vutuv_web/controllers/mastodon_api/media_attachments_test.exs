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
  alias Vutuv.MastodonApi
  alias Vutuv.Posts
  alias Vutuv.Posts.PostImage
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

    # A body that references the photo inline, the way the composer writes one.
    # Built here because it needs the image's URL, which only exists now.
    body =
      if attrs[:inline],
        do: "Seht her:\n\n![Ein Foto](#{PostImage.url(image, "large")})",
        else: "Mit Foto"

    attrs = Map.merge(%{body: body, image_ids: [image.id]}, Map.delete(attrs, :inline))
    {:ok, post} = Posts.create_post(author, attrs)

    {post, image}
  end

  defp content(conn, post) do
    conn |> get("/api/v1/statuses/#{post.id}") |> json_response(200) |> Map.fetch!("content")
  end

  # The src as a client parses it: an attribute value is HTML, so a URL joining
  # two query parameters arrives as `?v=…&amp;t=…` and only reads back as two
  # parameters once the entities are decoded. Asserting on the raw attribute
  # would pass on an uncropped photo and quietly fetch `amp;t` on a cropped one.
  defp inline_src(html) do
    case Regex.run(~r/<img[^>]*\bsrc="([^"]+)"/, html) do
      # Only `&` can occur in one of our image URLs, and decoding it last is the
      # rule that keeps a literal `&amp;amp;` from collapsing twice.
      [_, src] -> String.replace(src, "&amp;", "&")
      nil -> flunk("no inline <img> in: #{html}")
    end
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

  # Issue #1647: `media_attachments` was fixed first, but a client renders
  # `content` as HTML, and every URL the website's renderer writes into it is
  # root-relative — so the same photo referenced inline in the body stayed a
  # broken image even where its attachment loaded.
  describe "a photo referenced inline in the body" do
    test "is an absolute URL that loads, on a public post", %{conn: conn, tmp: tmp} do
      author = insert(:activated_user)
      {post, image} = local_photo_post(author, tmp, %{inline: true})

      conn = mastodon_conn(conn, mastodon_token(insert(:activated_user), ["read"]))
      src = conn |> content(post) |> inline_src()

      assert src == MastodonApi.main_url(PostImage.url(image, "large"))
      assert fetch(src).status == 200
    end

    test "carries the capability on a restricted post, and loads with it", %{
      conn: conn,
      tmp: tmp
    } do
      author = insert(:activated_user)
      reader = insert(:activated_user)
      follow!(reader, author)

      {post, image} =
        local_photo_post(author, tmp, %{inline: true, denials: [%{"wildcard" => "non_followers"}]})

      # Cropped, so the URL already carries the cache-buster the capability has
      # to be joined to rather than replace — the case `append_query/2` exists
      # for, and the one a bare `?t=` would silently break.
      Repo.update!(Ecto.Changeset.change(image, crop: "0,0,32,32"))

      conn = mastodon_conn(conn, mastodon_token(reader, ["read"]))
      src = conn |> content(post) |> inline_src()

      query = URI.decode_query(URI.parse(src).query)
      assert Map.has_key?(query, "t")
      assert Map.has_key?(query, "v")
      assert fetch(src).status == 200
    end

    # `render_remote/1` writes our hashtag and local-mention links root-relative
    # as well, so the two remote status heads had the same bug.
    test "and a cached remote post's own links are absolute", %{conn: conn} do
      tag = insert(:tag)
      insert(:user_tag, user: insert(:activated_user), tag: tag)

      post =
        cached_post(remote_account(), content_text: "Von woanders zum ##{tag.slug}")

      conn = mastodon_conn(conn, mastodon_token(federating_member(), ["read"]))

      html =
        conn
        |> get("/api/v1/statuses/remote-#{post.id}")
        |> json_response(200)
        |> Map.fetch!("content")

      assert html =~ ~s(href="#{MastodonApi.main_url("/tags/" <> tag.slug)}")
      refute html =~ ~s(href="/)
    end

    # The body's other root-relative URLs are the same bug: a client cannot
    # resolve them either.
    test "and the body's mentions and hashtags are absolute too", %{conn: conn} do
      author = insert(:activated_user)
      named = insert(:activated_user, username: unique_username("inline"))
      tag = insert(:tag)
      insert(:user_tag, user: named, tag: tag)

      {:ok, post} =
        Posts.create_post(author, %{body: "Hallo @#{named.username} zum ##{tag.slug}"})

      conn = mastodon_conn(conn, mastodon_token(insert(:activated_user), ["read"]))
      html = content(conn, post)

      assert html =~ ~s(href="#{MastodonApi.main_url("/" <> named.username)}")
      assert html =~ ~s(href="#{MastodonApi.main_url("/tags/" <> tag.slug)}")
      refute html =~ ~s(href="/)
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
