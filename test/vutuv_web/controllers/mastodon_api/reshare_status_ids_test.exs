defmodule VutuvWeb.MastodonApi.ReshareStatusIdsTest do
  @moduledoc """
  A reshare is a status of its own to a Mastodon client (issue #1588), so a
  client hands `repost-<uuid>` and the `remote-` family back to endpoints that
  were still resolving ids with `Vutuv.Posts.get_post/1` alone (issue #1596).
  `/statuses/:id` had learned the grammar and its neighbours had not, so tapping
  a reshare's likers row answered 404 for the very id the timeline had just
  handed over — and reporting such a status failed the same way.

  The writes split, because a delete cannot be taken back: `update` and `source`
  follow a reshare id through to the post it passed on and answer only for the
  caller's own, while `delete` acts on the reshare **row** and undoes it — never
  the post underneath, whoever wrote that.

  async: false — `mastodon_token/2` flips the member's client permission.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.PostBoost
  alias Vutuv.Fediverse.PostRepost, as: RemotePostRepost
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Posts
  alias Vutuv.Posts.PostRepost
  alias Vutuv.RateLimiter
  alias Vutuv.Repo
  alias VutuvWeb.MastodonApi.Statuses

  setup do
    author = insert(:activated_user)
    resharer = insert(:activated_user)
    liker = insert(:activated_user)

    {:ok, post} = Posts.create_post(author, %{body: "Weitergereicht"})
    :ok = Posts.like_post(liker, post)
    repost = repost_row(resharer, post)

    %{
      author: author,
      resharer: resharer,
      liker: liker,
      post: post,
      reshare_id: "repost-#{repost.id}"
    }
  end

  defp api(conn, user, scopes), do: mastodon_conn(conn, mastodon_token(user, scopes))

  describe "reads addressed at a reshare's id" do
    test "favourited_by answers the underlying post's likers", ctx do
      accounts =
        build_conn()
        |> api(ctx.resharer, ["read"])
        |> get("/api/v1/statuses/#{ctx.reshare_id}/favourited_by")
        |> json_response(200)

      assert Enum.map(accounts, & &1["id"]) == [ctx.liker.id]
    end

    test "reblogged_by answers the underlying post's resharers", ctx do
      accounts =
        build_conn()
        |> api(ctx.resharer, ["read"])
        |> get("/api/v1/statuses/#{ctx.reshare_id}/reblogged_by")
        |> json_response(200)

      assert Enum.map(accounts, & &1["id"]) == [ctx.resharer.id]
    end

    test "a cached remote status answers an empty list, not a 404", ctx do
      # Who reacted to somebody else's status is the origin's answer. What this
      # installation holds is only the slice that reached it, so the honest
      # reply is nothing at all — but the id must still resolve.
      remote = cached_post(remote_account())

      accounts =
        build_conn()
        |> api(ctx.resharer, ["read"])
        |> get("/api/v1/statuses/remote-#{remote.id}/favourited_by")
        |> json_response(200)

      assert accounts == []
    end

    test "an id naming nothing is still a 404", ctx do
      build_conn()
      |> api(ctx.resharer, ["read"])
      |> get("/api/v1/statuses/repost-#{Vutuv.UUIDv7.generate()}/favourited_by")
      |> json_response(404)
    end

    test "a post the asker may not read still answers 404", ctx do
      # The gate survived the move to the shared resolver. Deliberately a plain
      # post and not a reshare of one: a restricted post can never carry a
      # reshare, because the audience lock refuses to narrow a post once one
      # exists, so there is no such thing as a reshare id pointing at a post
      # somebody is denied.
      stranger = insert(:activated_user)

      {:ok, closed} =
        Posts.create_post(ctx.author, %{
          body: "Nicht für alle",
          denials: [%{"wildcard" => "non_followers"}]
        })

      build_conn()
      |> api(stranger, ["read"])
      |> get("/api/v1/statuses/#{closed.id}/favourited_by")
      |> json_response(404)
    end
  end

  describe "reporting a status by a reshare's id" do
    test "opens a case against the post underneath", ctx do
      reporter = insert(:activated_user)

      build_conn()
      |> api(reporter, ["read", "write"])
      |> post("/api/v1/reports", %{
        "account_id" => ctx.author.id,
        "status_ids" => [ctx.reshare_id]
      })
      |> json_response(200)

      # The case names the post underneath, not the reshare row.
      assert Repo.exists?(
               from(c in Vutuv.Moderation.Case,
                 where: c.content_type == "post" and c.content_id == ^ctx.post.id
               )
             )
    end
  end

  describe "an edit or a source read addressed at a reshare's id" do
    test "reaches the post underneath when it is the caller's own", ctx do
      # A boost from another server, because it is the one reshare that does not
      # itself close the edit window: `has_reposts?/1` counts only reshares made
      # here, so a `repost-` id always resolves to a post nobody may edit any
      # more (the test below).
      {:ok, mine} = Posts.create_post(ctx.author, %{body: "Meins"})
      boost = boost(remote_account(), mine)

      build_conn()
      |> api(ctx.author, ["read", "write"])
      |> put("/api/v1/statuses/boost-#{boost.id}", %{"status" => "Überarbeitet"})
      |> json_response(200)

      assert Posts.get_post(mine.id).body == "Überarbeitet"
    end

    test "says why an edit is refused instead of claiming the status is gone", ctx do
      # The reshare that made this id exist is also what closed the edit window,
      # so the answer is the rule rather than the old bare 404.
      repost = repost_row(ctx.author, ctx.post)

      %{"error" => error} =
        build_conn()
        |> api(ctx.author, ["read", "write"])
        |> put("/api/v1/statuses/repost-#{repost.id}", %{"status" => "Überarbeitet"})
        |> json_response(422)

      assert error =~ "can no longer be edited"
      assert Posts.get_post(ctx.post.id).body == "Weitergereicht"
    end

    test "source answers that post's Markdown", ctx do
      repost = repost_row(ctx.author, ctx.post)

      source =
        build_conn()
        |> api(ctx.author, ["read"])
        |> get("/api/v1/statuses/repost-#{repost.id}/source")
        |> json_response(200)

      assert source["id"] == ctx.post.id
      assert source["text"] == "Weitergereicht"
    end

    test "answers 404 for somebody else's post, which keeps its words", ctx do
      build_conn()
      |> api(ctx.resharer, ["read", "write"])
      |> put("/api/v1/statuses/#{ctx.reshare_id}", %{"status" => "Übernommen"})
      |> json_response(404)

      assert Posts.get_post(ctx.post.id).body == "Weitergereicht"
    end
  end

  describe "a delete addressed at a reshare's id" do
    test "undoes my own reshare and leaves the post standing", ctx do
      status =
        build_conn()
        |> api(ctx.resharer, ["read", "write"])
        |> delete("/api/v1/statuses/#{ctx.reshare_id}")
        |> json_response(200)

      # Mastodon answers a delete with the status the client addressed, so what
      # comes back is the reshare — carrying the post it passed on.
      assert status["id"] == ctx.reshare_id
      assert status["reblog"]["id"] == ctx.post.id

      refute Repo.get_by(PostRepost, post_id: ctx.post.id, user_id: ctx.resharer.id)
      assert Posts.get_post(ctx.post.id)
    end

    test "undoes my reshare of my own post rather than deleting the post", ctx do
      # The one id that names two things the caller owns. It names the act.
      repost = repost_row(ctx.author, ctx.post)

      build_conn()
      |> api(ctx.author, ["read", "write"])
      |> delete("/api/v1/statuses/repost-#{repost.id}")
      |> json_response(200)

      refute Repo.get(PostRepost, repost.id)
      assert Posts.get_post(ctx.post.id)
    end

    test "never reaches the post underneath somebody else's reshare", ctx do
      # The case worth being careful about: the author owns the post this id
      # resolves to, so a delete routed through the read resolver would take the
      # original down instead of the reshare — and `unrepost_post/2` finds the
      # *caller's* reshare, so routing it to the undo would have been wrong too.
      build_conn()
      |> api(ctx.author, ["read", "write"])
      |> delete("/api/v1/statuses/#{ctx.reshare_id}")
      |> json_response(404)

      assert Posts.get_post(ctx.post.id)
      assert Repo.get_by(PostRepost, post_id: ctx.post.id, user_id: ctx.resharer.id)
    end

    test "undoes my reshare of a post from another network" do
      RateLimiter.reset()
      sharer = federating_member()
      remote = cached_post(remote_account())

      {:ok, :reposted} = Fediverse.repost_remote_post(sharer, remote)
      repost = Repo.get_by!(RemotePostRepost, remote_post_id: remote.id, user_id: sharer.id)

      status =
        build_conn()
        |> api(sharer, ["read", "write"])
        |> delete("/api/v1/statuses/remote-repost-#{repost.id}")
        |> json_response(200)

      assert status["id"] == "remote-repost-#{repost.id}"
      refute Repo.get(RemotePostRepost, repost.id)
      assert Repo.get(RemotePost, remote.id)
    end

    test "a boost from another server is nobody here's to undo", ctx do
      # `fediverse_post_boosts` belongs to a remote account, so no member and no
      # page can ever own the row that id names.
      boost = boost(remote_account(), ctx.post)

      build_conn()
      |> api(ctx.author, ["read", "write"])
      |> delete("/api/v1/statuses/boost-#{boost.id}")
      |> json_response(404)

      assert Repo.get(PostBoost, boost.id)
      assert Posts.get_post(ctx.post.id)
    end
  end

  describe "an id word this module has not learned" do
    test "fails closed instead of reaching the post lookup" do
      # The safeguard rests on `resolve/1` and `own_reshare/2` knowing the same
      # words, and they are two lists in one file. The day one grows a prefix the
      # other does not, this default decides: `:not_a_reshare` would hand that id
      # to the ordinary post lookup, which resolves a reshare to the post
      # underneath — the deletion the whole split exists to prevent.
      conn = build_conn()

      assert Statuses.own_reshare(conn, "quote-#{Vutuv.UUIDv7.generate()}") == :not_mine
      assert Statuses.own_reshare(conn, Vutuv.UUIDv7.generate()) == :not_a_reshare
    end
  end

  # `user` passes `post` on, and the row that records it — the thing a reshare's
  # id names.
  defp repost_row(user, post) do
    Posts.repost_post(user, post)
    Repo.get_by!(PostRepost, post_id: post.id, user_id: user.id)
  end
end
