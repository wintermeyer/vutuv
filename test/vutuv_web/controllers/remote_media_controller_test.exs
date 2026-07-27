defmodule VutuvWeb.RemoteMediaControllerTest do
  @moduledoc """
  The proxy that serves the pictures cached from other networks (issue #1163).

  It is the whole access control for those files, so every refusal it makes is
  tested here rather than asserted in a moduledoc: a signed-out request, a
  reader who does not follow the author, a follow the author never accepted, a
  picture the AI gate has not cleared, and a URL whose version segment names
  bytes we no longer store. An unguessable URL is not an access control.
  """
  use VutuvWeb.ConnCase, async: true

  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemoteImage
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.RemoteMedia

  setup %{conn: conn} do
    {conn, user} = create_and_login_user(Plug.Test.init_test_session(conn, %{}))

    account =
      Repo.insert!(%RemoteAccount{
        actor_uri: "https://social.example/users/them#{System.unique_integer([:positive])}",
        host: "social.example",
        handle: "them",
        inbox_uri: "https://social.example/inbox"
      })

    %{conn: conn, user: user, account: account, out: build_conn()}
  end

  defp remote_post(account, audience \\ "public") do
    now = DateTime.utc_now(:second)

    Repo.insert!(%RemotePost{
      remote_account_id: account.id,
      object_uri: "https://social.example/p/#{System.unique_integer([:positive])}",
      content_text: "Mit Bild.",
      audience: audience,
      kind: "note",
      published_at: now,
      received_at: now,
      expires_at: DateTime.add(now, 86_400)
    })
  end

  # A stored picture, written straight to disk: what is under test is who may
  # read it, not how it got here.
  defp picture(post, attrs \\ %{}) do
    row =
      Repo.insert!(
        struct(
          %RemoteImage{
            remote_post_id: post.id,
            source_uri: "https://social.example/media/#{System.unique_integer([:positive])}.jpg",
            position: 0,
            moderation: "approved"
          },
          attrs
        )
      )

    {:ok, %{file: file}} = RemoteMedia.store_post_image(jpeg_bytes(), row.id)
    Repo.update!(change(row, file: file))
  end

  defp avatar(account) do
    {:ok, %{file: file}} = RemoteMedia.store_avatar(jpeg_bytes(), account.id)
    Repo.update!(change(account, avatar: file, avatar_moderation: "approved"))
  end

  defp jpeg_bytes do
    {:ok, image} = Image.new(8, 8, color: [10, 20, 30])
    {:ok, bytes} = Image.write(image, :memory, suffix: ".jpg")
    bytes
  end

  defp media_url(%RemoteImage{} = image), do: RemoteMedia.post_image_url(image.id, image.file)

  defp media_url(%RemoteAccount{} = account),
    do: RemoteMedia.avatar_url(account.id, account.avatar)

  defp follow(user, account, state) do
    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: state,
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#f/#{account.id}"
    })
  end

  describe "a post picture" do
    test "is served to a reader who follows its author", ctx do
      image = picture(remote_post(ctx.account))
      follow(ctx.user, ctx.account, "accepted")

      conn = get(ctx.conn, media_url(image))

      assert conn.status == 200
      # It must never turn up as our picture in an image search.
      assert get_resp_header(conn, "x-robots-tag") == ["noindex, noimageindex"]
    end

    test "is not served to somebody who is not signed in", ctx do
      image = picture(remote_post(ctx.account))
      follow(ctx.user, ctx.account, "accepted")

      assert get(ctx.out, media_url(image)).status == 404
    end

    test "is not served to a signed-in member who follows nobody here", ctx do
      image = picture(remote_post(ctx.account))

      assert get(ctx.conn, media_url(image)).status == 404
    end

    test "a followers-only post's picture needs an accepted follow", ctx do
      image = picture(remote_post(ctx.account, "followers"))
      follow_row = follow(ctx.user, ctx.account, "requested")

      assert get(ctx.conn, media_url(image)).status == 404

      Repo.update!(change(follow_row, state: "accepted"))

      assert get(recycle(ctx.conn), media_url(image)).status == 200
    end

    test "nothing is served before the AI gate has cleared it", ctx do
      image = picture(remote_post(ctx.account), %{moderation: "pending"})
      follow(ctx.user, ctx.account, "accepted")

      assert get(ctx.conn, media_url(image)).status == 404
    end

    test "a URL naming bytes we no longer store stops answering", ctx do
      image = picture(remote_post(ctx.account))
      follow(ctx.user, ctx.account, "accepted")
      stale = media_url(image)
      # The gate rejected it: the row keeps its id, the file is gone.
      Repo.update!(change(image, file: nil, moderation: "rejected"))

      assert get(ctx.conn, stale).status == 404
    end

    test "and so does a made-up version segment", ctx do
      image = picture(remote_post(ctx.account))
      follow(ctx.user, ctx.account, "accepted")

      assert get(ctx.conn, "/system/remote_media/posts/#{image.id}/made-up.avif").status == 404
    end
  end

  describe "an account's avatar" do
    test "is served to a signed-in reader", ctx do
      stored = avatar(ctx.account)

      assert get(ctx.conn, media_url(stored)).status == 200
    end

    test "is not served to somebody who is not signed in", ctx do
      stored = avatar(ctx.account)

      assert get(ctx.out, media_url(stored)).status == 404
    end

    test "is not served before the gate has cleared it", ctx do
      stored = avatar(ctx.account)
      Repo.update!(change(stored, avatar_moderation: "pending"))

      assert get(ctx.conn, media_url(stored)).status == 404
    end
  end
end
