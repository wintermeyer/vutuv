defmodule VutuvWeb.RemoteMediaControllerTest do
  @moduledoc """
  The proxy that serves the pictures cached from other networks (issue #1163).

  It is the whole access control for those files, so every refusal it makes is
  tested here rather than asserted in a moduledoc: a signed-out request, a
  followers-only post without an accepted follow, a picture the AI gate has not
  cleared, and a URL whose version segment names bytes we no longer store. An
  unguessable URL is not an access control.

  And every *admission*, because the first version of this proxy asked for the
  viewer's own follow of the author and so 404ed every picture on a boosted or
  reshared post — a photo post out of the feed came out as broken images. The
  ways a cached post legitimately reaches a reader are covered one by one below.
  """
  use VutuvWeb.ConnCase, async: true

  import Vutuv.MastodonHelpers, only: [avatar_capability: 1]

  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.PostBoost
  alias Vutuv.Fediverse.PostRepost
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemoteImage
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.MastodonApi.Presenter
  alias Vutuv.RemoteMedia
  alias VutuvWeb.RemoteMediaToken

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

  defp other_account do
    Repo.insert!(%RemoteAccount{
      actor_uri: "https://other.example/users/them#{System.unique_integer([:positive])}",
      host: "other.example",
      handle: "booster",
      inbox_uri: "https://other.example/inbox"
    })
  end

  defp boost(booster, post) do
    Repo.insert!(%PostBoost{
      remote_account_id: booster.id,
      remote_post_id: post.id,
      activity_id: "https://other.example/a/#{System.unique_integer([:positive])}",
      announced_at: DateTime.utc_now(:second)
    })
  end

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

    test "an open post's picture is served to any signed-in member", ctx do
      # The account page already shows them the post itself, and a boost or a
      # member's repost carries it into a feed without any follow of the author,
      # so the picture must not be stricter than the text beside it.
      image = picture(remote_post(ctx.account))

      assert get(ctx.conn, media_url(image)).status == 200
    end

    test "a followers-only post's picture is not, without a follow", ctx do
      image = picture(remote_post(ctx.account, "followers"))

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

    test "is served when a followed account boosted the post", ctx do
      # The normal boost (issue #1167): the reader follows the booster, nobody
      # here follows the author, and the feed shows them the card all the same.
      image = picture(remote_post(ctx.account))
      booster = other_account()
      boost(booster, %RemotePost{id: image.remote_post_id})
      follow(ctx.user, booster, "accepted")

      assert get(ctx.conn, media_url(image)).status == 200
    end

    test "a boost does not widen a followers-only post", ctx do
      image = picture(remote_post(ctx.account, "followers"))
      booster = other_account()
      boost(booster, %RemotePost{id: image.remote_post_id})
      follow(ctx.user, booster, "accepted")

      assert get(ctx.conn, media_url(image)).status == 404
    end

    test "is served when a member here reshared the post", ctx do
      # Issue #1166: the reposter is the reason the reader sees it at all.
      image = picture(remote_post(ctx.account))
      Repo.insert!(%PostRepost{user_id: ctx.user.id, remote_post_id: image.remote_post_id})

      assert get(ctx.conn, media_url(image)).status == 200
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

  describe "the URL the Mastodon adapter hands a client" do
    # The seam #1588 opened: the adapter started naming the cached picture
    # instead of the installation's icon, and an image loader fetches with a
    # bare GET — no cookie, no bearer, because that is what every image loader
    # does. So the picture the API had just named came back 404 and every
    # account out of the fediverse sat blank in the app.
    test "loads without a session, because that is how an image loader asks", ctx do
      stored = avatar(ctx.account)

      assert get(ctx.out, adapter_path(stored)).status == 200
    end

    test "is refused when the query carries something that is not one", ctx do
      stored = avatar(ctx.account)

      assert get(ctx.out, media_url(stored) <> "?t=not-a-token").status == 404
    end

    # Expiry is the whole difference between a capability and the unguessable
    # URL the proxy's moduledoc refuses, so both ends of the window are pinned.
    test "stops opening the picture once it has expired", ctx do
      stored = avatar(ctx.account)
      stale = minted_ago(stored, RemoteMediaToken.max_age() + 86_400)

      refute RemoteMediaToken.avatar?(avatar_capability("?" <> stale), stored.id, stored.avatar)
      assert get(ctx.out, media_url(stored) <> "?" <> stale).status == 404
    end

    # The other end, and the one a reader would report: a client may still be
    # showing a timeline it cached days ago, and those URLs have to keep
    # working. It is also the only guard on `verify/4`'s `max_age:` option —
    # drop it and Plug.Crypto falls back to the ONE DAY it bakes in at signing
    # time, which is *stricter*, so no expiry test can catch that. Every
    # capability older than a day would 404 and every face would go blank
    # again, which is the bug this whole module exists to fix.
    test "still opens it a day inside the window", ctx do
      stored = avatar(ctx.account)
      old = minted_ago(stored, RemoteMediaToken.max_age() - 86_400)

      assert get(ctx.out, media_url(stored) <> "?" <> old).status == 200
    end

    test "stops answering once the gate takes the picture back", ctx do
      stored = avatar(ctx.account)
      path = adapter_path(stored)

      Repo.update!(change(stored, avatar_moderation: "pending"))

      assert get(ctx.out, path).status == 404
    end

    test "does not open another account's picture", ctx do
      other = avatar(other_account())
      borrowed = ctx.account |> avatar() |> capability()

      assert get(ctx.out, media_url(other) <> "?" <> borrowed).status == 404
    end
  end

  # The avatar URL as a client receives it, reduced to what ConnTest requests.
  defp adapter_path(%RemoteAccount{} = account),
    do: media_url(account) <> "?" <> capability(account)

  defp capability(%RemoteAccount{} = account) do
    %URI{query: query} = account |> Presenter.account() |> Map.fetch!(:avatar) |> URI.parse()
    query
  end

  # A capability as it would have been minted `seconds` ago — the injectable
  # clock, so the expiry tests never wait and never read the real one.
  defp minted_ago(%RemoteAccount{id: id, avatar: file}, seconds),
    do: RemoteMediaToken.avatar_query(id, file, System.os_time(:second) - seconds)
end
