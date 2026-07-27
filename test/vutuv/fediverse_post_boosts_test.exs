defmodule Vutuv.FediversePostBoostsTest do
  @moduledoc """
  What an account somebody here follows has re-shared (issue #1167): what is
  fetched, what is refused unseen, and what reaches the follower's feed.

  `async: false` — the per-host fetch budget and the HTTP stub both live in
  application/ETS state the SQL sandbox does not roll back.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.PostBoost
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Posts

  @booster "https://social.example/users/kurator"
  @author "https://third.example/users/autorin"
  @object "https://third.example/notes/1"
  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  # An author whose posts really federate: `local_note_post/1` refuses to
  # redistribute a member who opted out, which is the whole point of that gate.
  defp federating_author do
    user = insert(:activated_user, fediverse_followers?: true)
    {:ok, _actor} = Fediverse.ensure_actor(user)
    Repo.reload!(user)
  end

  defp booster_account do
    Repo.insert!(%RemoteAccount{
      actor_uri: @booster,
      host: "social.example",
      handle: "kurator",
      name: "Die Kuratorin",
      inbox_uri: @booster <> "/inbox"
    })
  end

  defp follower_of(account, state \\ "accepted") do
    user = insert(:activated_user, fediverse_followers?: true)
    {:ok, _actor} = Fediverse.ensure_actor(user)

    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: state,
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#f/#{account.id}"
    })

    Repo.reload!(user)
  end

  defp announce(object \\ @object) do
    %{
      "id" => @booster <> "#announces/1",
      "type" => "Announce",
      "actor" => @booster,
      "published" => "2026-07-27T10:00:00Z",
      "object" => object
    }
  end

  # The third server answering for the announced object and for its author.
  defp serve_third(note_overrides \\ %{}) do
    note =
      Map.merge(
        %{
          "id" => @object,
          "type" => "Note",
          "attributedTo" => @author,
          "content" => "<p>Etwas von ganz woanders.</p>",
          "published" => "2026-07-27T09:00:00Z",
          "to" => [@public]
        },
        note_overrides
      )

    actor = %{
      "id" => @author,
      "type" => "Person",
      "preferredUsername" => "autorin",
      "inbox" => @author <> "/inbox"
    }

    Application.put_env(:vutuv, :fediverse_req_options,
      plug: fn conn ->
        body = if conn.request_path =~ "notes", do: note, else: actor

        conn
        |> Plug.Conn.put_resp_content_type("application/activity+json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
  end

  defp refuse_all do
    Application.put_env(:vutuv, :fediverse_req_options,
      plug: fn conn -> Plug.Conn.send_resp(conn, 500, "") end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
  end

  describe "a third party's post" do
    setup do
      acc = booster_account()
      %{account: acc, user: follower_of(acc)}
    end

    test "is fetched, stored once and shown under who passed it on", ctx do
      serve_third()

      assert :ok = Fediverse.record_remote_boost(announce(), @booster)

      assert [post] = Repo.all(RemotePost)
      assert post.object_uri == @object
      assert post.content_text == "Etwas von ganz woanders."
      # Its author is a third server we had never spoken to; the card has to
      # name who wrote it, so their account was resolved too.
      assert Repo.get_by!(RemoteAccount, actor_uri: @author).host == "third.example"

      assert [entry] = Posts.feed_page(ctx.user).entries
      assert entry.remote_post.id == post.id
      # The messenger, never the writer: the header still attributes the post
      # to its own author.
      assert entry.boosted_by.actor_uri == @booster
    end

    test "a redelivery stores one boost and fetches once", ctx do
      serve_third()

      assert :ok = Fediverse.record_remote_boost(announce(), @booster)
      assert :ok = Fediverse.record_remote_boost(announce(), @booster)

      assert Repo.aggregate(PostBoost, :count) == 1
      assert Repo.aggregate(RemotePost, :count) == 1
      assert [_entry] = Posts.feed_page(ctx.user).entries
    end

    test "the account taking it back removes the boost, not the post", ctx do
      serve_third()
      :ok = Fediverse.record_remote_boost(announce(), @booster)

      # The shape the inbox really hands over: the `Undo` wrapping the whole
      # `Announce` it takes back, whose own id is what names the boost row.
      assert :ok =
               Fediverse.remove_remote_boost(
                 %{"type" => "Undo", "actor" => @booster, "object" => announce()},
                 @booster
               )

      assert Repo.aggregate(PostBoost, :count) == 0
      assert Posts.feed_page(ctx.user).entries == []
      # The post row stays for now; the ordinary sweeps take it once nothing
      # holds it.
      assert Repo.aggregate(RemotePost, :count) == 1
    end
  end

  describe "what is refused" do
    setup do
      acc = booster_account()
      %{account: acc, user: follower_of(acc)}
    end

    test "an Announce from an account nobody here follows", _ctx do
      serve_third()
      other = "https://elsewhere.example/users/stranger"

      assert :skip = Fediverse.record_remote_boost(announce(), other)
      assert Repo.aggregate(RemotePost, :count) == 0
    end

    test "an account whose follow was never accepted" do
      acc =
        Repo.insert!(%RemoteAccount{
          actor_uri: "https://social.example/users/pending",
          host: "social.example",
          handle: "pending",
          inbox_uri: "https://social.example/users/pending/inbox"
        })

      follower_of(acc, "requested")
      serve_third()

      assert :skip =
               Fediverse.record_remote_boost(announce(), "https://social.example/users/pending")
    end

    test "a blocked host, before anything is fetched", _ctx do
      {:ok, _} =
        Fediverse.block_instance(%{"host" => "third.example"}, insert(:user, admin?: true))

      # No stub at all: reaching the network would raise, which is the point.
      assert :skip = Fediverse.record_remote_boost(announce(), @booster)
      assert Repo.aggregate(RemotePost, :count) == 0
    end

    test "an object that is not public or unlisted is never stored" do
      serve_third(%{"to" => [@author <> "/followers"]})

      # Somebody boosting a followers-only post of a third party's does not make
      # it ours to keep.
      assert :skip = Fediverse.record_remote_boost(announce(), @booster)
      assert Repo.aggregate(RemotePost, :count) == 0
    end

    test "a fetch that fails drops the boost silently, with no retry" do
      refuse_all()

      assert :skip = Fediverse.record_remote_boost(announce(), @booster)
      assert Repo.aggregate(PostBoost, :count) == 0
    end

    test "the per-host budget stops a relentless booster" do
      Application.put_env(:vutuv, :fediverse_announce_fetch_limit, 1)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_announce_fetch_limit) end)

      serve_third()
      assert :ok = Fediverse.record_remote_boost(announce(), @booster)

      # A second, different object on the same host: the budget is what stops
      # one account walking us through a stranger's whole archive.
      assert :skip =
               Fediverse.record_remote_boost(
                 announce("https://third.example/notes/2"),
                 @booster
               )
    end
  end

  describe "a vutuv member's own post" do
    setup do
      acc = booster_account()
      %{account: acc, user: follower_of(acc)}
    end

    test "is shown with no network call at all", ctx do
      author = federating_author()
      {:ok, post} = Posts.create_post(author, %{body: "Von hier."})
      url = "#{VutuvWeb.Endpoint.url()}/#{author.username}/posts/#{post.id}"

      # No HTTP stub: any fetch would raise. This is how members get discovered
      # through the outside network, and it must cost nothing.
      assert :ok = Fediverse.record_remote_boost(announce(url), @booster)

      assert [boost] = Repo.all(PostBoost)
      assert boost.post_id == post.id
      assert is_nil(boost.remote_post_id)

      assert entry = Enum.find(Posts.feed_page(ctx.user).entries, &(&1[:boosted_by] != nil))
      assert entry.post.id == post.id
      assert entry.boosted_by.actor_uri == @booster
    end

    test "a restricted post is not carried outward by somebody else's boost", ctx do
      author = federating_author()
      other = insert(:activated_user)

      {:ok, post} =
        Posts.create_post(author, %{
          body: "Nur für wenige.",
          denials: [%{"denied_user_id" => other.id}]
        })

      url = "#{VutuvWeb.Endpoint.url()}/#{author.username}/posts/#{post.id}"

      assert :skip = Fediverse.record_remote_boost(announce(url), @booster)
      assert Repo.aggregate(PostBoost, :count) == 0
      assert ctx.user
    end
  end

  describe "a server may only speak for itself" do
    setup do
      acc = booster_account()
      %{account: acc, user: follower_of(acc)}
    end

    test "a note claiming somebody else's authorship is refused", _ctx do
      # The forgery: evil.example serves an object attributed to a real account
      # on another server. Storing it would publish evil's words under that
      # person's name, handle and avatar — and they could never get it removed,
      # because their own Delete names an object URI on their own host.
      serve_third(%{"attributedTo" => "https://mastodon.example/users/somebody"})

      assert :skip = Fediverse.record_remote_boost(announce(), @booster)
      assert Repo.aggregate(RemotePost, :count) == 0
      refute Repo.get_by(RemoteAccount, actor_uri: "https://mastodon.example/users/somebody")
    end

    test "a note whose id is on another host is refused", _ctx do
      # Squatting a genuine post's URI would poison it here for the row's whole
      # life: the real Create would later be dropped as a duplicate.
      serve_third(%{"id" => "https://mastodon.example/users/x/statuses/1"})

      assert :skip = Fediverse.record_remote_boost(announce(), @booster)
      assert Repo.aggregate(RemotePost, :count) == 0
    end

    test "a note claiming to be written by one of our own members is refused", _ctx do
      member = insert(:activated_user)
      serve_third(%{"attributedTo" => "#{VutuvWeb.Endpoint.url()}/#{member.username}/actor"})

      assert :skip = Fediverse.record_remote_boost(announce(), @booster)
      # And no ghost "remote" account row for a local member.
      assert Repo.aggregate(RemoteAccount, :count) == 1
    end

    test "an object that is not a Note or a Question is refused", _ctx do
      serve_third(%{"type" => "Video"})

      assert :skip = Fediverse.record_remote_boost(announce(), @booster)
      assert Repo.aggregate(RemotePost, :count) == 0
    end
  end

  describe "a boosted vutuv post obeys the reader's own view" do
    setup do
      acc = booster_account()
      user = follower_of(acc)
      %{account: acc, user: user, author: federating_author()}
    end

    defp boost_local(post, author) do
      url = "#{VutuvWeb.Endpoint.url()}/#{author.username}/posts/#{post.id}"
      Fediverse.record_remote_boost(announce(url), @booster)
    end

    test "a blocked author's post does not arrive through somebody else's boost", ctx do
      {:ok, post} = Posts.create_post(ctx.author, %{body: "Von hier."})
      assert :ok = boost_local(post, ctx.author)

      {:ok, _} = Vutuv.Social.block_user(ctx.user, ctx.author)

      assert Posts.feed_page(ctx.user).entries == []
    end

    test "a frozen post stops travelling", ctx do
      {:ok, post} = Posts.create_post(ctx.author, %{body: "Von hier."})
      assert :ok = boost_local(post, ctx.author)
      assert [_] = Posts.feed_page(ctx.user).entries

      # Reported and frozen after the boost: the boost must not keep carrying it.
      Repo.update_all(Vutuv.Posts.Post, set: [frozen_at: NaiveDateTime.utc_now(:second)])

      assert Posts.feed_page(ctx.user).entries == []
    end

    test "a member who does not federate is not redistributed at all", _ctx do
      author = insert(:activated_user)
      {:ok, post} = Posts.create_post(author, %{body: "Nicht föderiert."})

      # They opted out; a remote actor's say-so does not override that.
      assert :skip = boost_local(post, author)
      assert Repo.aggregate(PostBoost, :count) == 0
    end
  end

  describe "the inbound cap" do
    test "a relentless booster is metered like every other inbound activity" do
      Application.put_env(:vutuv, :fediverse_inbound_caps, {600, 1})
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_inbound_caps) end)

      acc = booster_account()
      follower_of(acc)
      author = federating_author()
      {:ok, first} = Posts.create_post(author, %{body: "Eins."})
      {:ok, second} = Posts.create_post(author, %{body: "Zwei."})

      url = fn post ->
        "#{VutuvWeb.Endpoint.url()}/#{author.username}/posts/#{post.id}"
      end

      # A boost of a local post needs no fetch, so the per-host fetch budget
      # never sees it: without the inbound cap it would be a free write.
      assert :ok = Fediverse.record_remote_boost(announce(url.(first)), @booster)
      assert :skip = Fediverse.record_remote_boost(announce(url.(second)), @booster)
    end
  end

  describe "retention" do
    test "a boosted copy is spared the unfollowed purge" do
      acc = booster_account()
      follower_of(acc)
      serve_third()
      :ok = Fediverse.record_remote_boost(announce(), @booster)

      # Nobody here follows the *author* — that is the normal case for a boost,
      # and the reason the copy exists is the boost.
      assert Fediverse.purge_unfollowed_remote_posts() == 0
      assert Repo.aggregate(RemotePost, :count) == 1
    end
  end
end
