defmodule VutuvWeb.MastodonApi.ReshareStatusIdsTest do
  @moduledoc """
  A reshare is a status of its own to a Mastodon client (issue #1588), so a
  client hands `repost-<uuid>` and the `remote-` family back to endpoints that
  were still resolving ids with `Vutuv.Posts.get_post/1` alone (issue #1596).
  `/statuses/:id` had learned the grammar and its neighbours had not, so tapping
  a reshare's likers row answered 404 for the very id the timeline had just
  handed over — and reporting such a status failed the same way.

  The writes (`update`, `delete`, `source`) deliberately still refuse a reshare
  id; see `VutuvWeb.MastodonApi.Statuses` for what undoing one properly needs.

  async: false — `mastodon_token/2` flips the member's client permission.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.MastodonHelpers

  alias Vutuv.Posts
  alias Vutuv.Posts.PostRepost
  alias Vutuv.Repo

  setup do
    author = insert(:activated_user)
    resharer = insert(:activated_user)
    liker = insert(:activated_user)

    {:ok, post} = Posts.create_post(author, %{body: "Weitergereicht"})
    :ok = Posts.like_post(liker, post)
    Posts.repost_post(resharer, post)

    repost = Repo.get_by!(PostRepost, post_id: post.id, user_id: resharer.id)

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

  describe "writes addressed at a reshare's id" do
    test "an edit is refused, and the post keeps its words", ctx do
      build_conn()
      |> api(ctx.resharer, ["read", "write"])
      |> put("/api/v1/statuses/#{ctx.reshare_id}", %{"status" => "Übernommen"})

      assert Posts.get_post(ctx.post.id).body == "Weitergereicht"
    end

    test "a delete never reaches the post underneath", ctx do
      # The case worth being careful about: the author owns the post this id
      # resolves to, so a delete routed through the read resolver would take the
      # original down instead of the reshare.
      build_conn()
      |> api(ctx.author, ["read", "write"])
      |> delete("/api/v1/statuses/#{ctx.reshare_id}")

      assert Posts.get_post(ctx.post.id)
      assert Repo.get_by(PostRepost, post_id: ctx.post.id, user_id: ctx.resharer.id)
    end
  end
end
