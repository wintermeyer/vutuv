defmodule Vutuv.FediverseThreadRepliesTest do
  @moduledoc """
  How many people answered a post from another network, and reading those
  answers here.

  The like and repost figures beside this one are read out of a document we
  already hold. The answer count is not: forty objects from this installation's
  own cache were asked before the feature was built and **not one** of their
  servers put a `totalItems` on `replies`. So the figure is counted by walking
  the collection, which costs a request, and everything in here is about paying
  that price once and no more often than it is worth.

  `async: false` — the stub is a global `Application.put_env/3` and the hourly
  fetch budget lives in the shared `Vutuv.RateLimiter` table, which the SQL
  sandbox does not roll back.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Fediverse.RemotePostTag
  alias Vutuv.FeedBand
  alias Vutuv.Tags.Timeline

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  defp account(host \\ "social.example") do
    uri = "https://#{host}/users/them#{System.unique_integer([:positive])}"

    Repo.insert!(%RemoteAccount{
      actor_uri: uri,
      host: host,
      handle: "them",
      inbox_uri: uri <> "/inbox"
    })
  end

  defp federating_member do
    user = insert(:activated_user, fediverse_followers?: true)
    {:ok, _actor} = Fediverse.ensure_actor(user)
    Repo.reload!(user)
  end

  defp follow(user, acc) do
    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: acc.id,
      state: "accepted",
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#f/#{acc.id}"
    })
  end

  defp cached_post(acc, attrs) do
    now = DateTime.utc_now(:second)

    Repo.insert!(
      struct(
        %RemotePost{
          remote_account_id: acc.id,
          object_uri: "https://#{acc.host}/p/#{System.unique_integer([:positive])}",
          content_text: "Welche Distro soll ich nehmen?",
          audience: "public",
          kind: "note",
          published_at: now,
          received_at: now,
          expires_at: DateTime.add(now, 86_400)
        },
        attrs
      )
    )
    |> Repo.preload(:remote_account)
  end

  defp followed_post(attrs \\ %{}) do
    acc = account()
    user = federating_member()
    follow(user, acc)
    {cached_post(acc, attrs), user}
  end

  # A fake network: every request is answered from `routes`, keyed by the full
  # URL. Anything not listed is a 404, which is what an id nobody serves really
  # does — so a test never passes on a stub being generous.
  defp serve(routes, opts \\ []) do
    seen = Keyword.get(opts, :seen)

    Application.put_env(:vutuv, :fediverse_req_options,
      plug: fn conn ->
        url = "https://#{conn.host}#{conn.request_path}" <> query_suffix(conn)
        if seen, do: send(seen, {:asked, url})

        case Map.fetch(routes, url) do
          {:ok, doc} ->
            conn
            |> Plug.Conn.put_resp_content_type("application/activity+json")
            |> Plug.Conn.send_resp(200, Jason.encode!(doc))

          :error ->
            Plug.Conn.send_resp(conn, 404, "")
        end
      end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :fediverse_req_options) end)
  end

  defp query_suffix(%{query_string: ""}), do: ""
  defp query_suffix(%{query_string: query}), do: "?" <> query

  defp object(post, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => post.object_uri,
        "type" => "Note",
        "content" => "<p>Welche Distro soll ich nehmen?</p>",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "attributedTo" => post.remote_account.actor_uri,
        "likes" => %{"type" => "Collection", "totalItems" => 28},
        "shares" => %{"type" => "Collection", "totalItems" => 22}
      },
      overrides
    )
  end

  # Mastodon's exact shape: the collection's first page is embedded in the
  # object and carries the author's own follow-ups, and its `next` is where
  # everybody else's answers are.
  defp replies_collection(post, own, others_page) do
    %{
      "id" => post.object_uri <> "/replies",
      "type" => "Collection",
      "first" =>
        %{
          "type" => "CollectionPage",
          "partOf" => post.object_uri <> "/replies",
          "items" => own
        }
        |> put_next(others_page)
    }
  end

  defp put_next(page, nil), do: page
  defp put_next(page, uri), do: Map.put(page, "next", uri)

  defp page(items, next \\ nil) do
    put_next(%{"type" => "CollectionPage", "items" => items}, next)
  end

  describe "counting the answers" do
    test "walks the collection and stores what it counted" do
      {post, _user} = followed_post()
      others = post.object_uri <> "/replies?only_other_accounts=true&page=true"

      serve(%{
        post.object_uri => object(post, %{"replies" => replies_collection(post, [], others)}),
        others =>
          page([
            "https://a.example/1",
            "https://b.example/2",
            "https://c.example/3"
          ])
      })

      assert :updated = Fediverse.refresh_counts(post)

      stored = Repo.get!(RemotePost, post.id)
      assert stored.replies_count == 3
      assert stored.replies_checked_at
      assert stored.replies_failures == 0
      # The two cheap figures still ride the same ask.
      assert stored.likes_count == 28
      assert stored.shares_count == 22
    end

    test "the author's own follow-ups on the embedded first page are counted too" do
      {post, _user} = followed_post()
      others = post.object_uri <> "/replies?only_other_accounts=true&page=true"

      serve(%{
        post.object_uri =>
          object(post, %{
            "replies" => replies_collection(post, ["https://social.example/p/self"], others)
          }),
        others => page(["https://a.example/1"])
      })

      assert :updated = Fediverse.refresh_counts(post)
      assert Repo.get!(RemotePost, post.id).replies_count == 2
    end

    test "stops after the page cap rather than walking a thousand answers" do
      {post, _user} = followed_post()
      p2 = post.object_uri <> "/replies?page=2"
      p3 = post.object_uri <> "/replies?page=3"
      p4 = post.object_uri <> "/replies?page=4"

      serve(%{
        post.object_uri => object(post, %{"replies" => replies_collection(post, [], p2)}),
        p2 => page(["https://a.example/1"], p3),
        p3 => page(["https://a.example/2"], p4),
        # Never asked for: three pages is the cap, and the fourth is where the
        # exact figure stops being what anybody is reading.
        p4 => page(["https://a.example/3"])
      })

      assert :updated = Fediverse.refresh_counts(post)
      assert Repo.get!(RemotePost, post.id).replies_count == 2
    end

    test "a totalItems is believed rather than counted past" do
      {post, _user} = followed_post()

      serve(%{
        post.object_uri =>
          object(post, %{
            "replies" => %{"type" => "Collection", "totalItems" => 940, "items" => []}
          })
      })

      assert :updated = Fediverse.refresh_counts(post)
      assert Repo.get!(RemotePost, post.id).replies_count == 940
    end

    # The deadlock this guards against is the one issue #1316 shipped: an
    # object that can never be worked on stays due forever, holds the front of
    # every batch, and the sweep silently stops doing anything at all.
    test "an origin that serves no replies collection is not asked again and again" do
      {post, _user} = followed_post()
      serve(%{post.object_uri => object(post)})

      assert :updated = Fediverse.refresh_counts(post)

      stored = Repo.get!(RemotePost, post.id)
      # Nothing to count, so no figure — a `0` would be a claim we cannot make.
      assert is_nil(stored.replies_count)
      # But the clock moved, which is what keeps it out of the next batch.
      assert stored.replies_checked_at
      assert stored.replies_failures == 0
    end

    test "a second ask inside the tier does not walk the collection again" do
      {post, _user} = followed_post()
      others = post.object_uri <> "/replies?only_other_accounts=true&page=true"

      routes = %{
        post.object_uri => object(post, %{"replies" => replies_collection(post, [], others)}),
        others => page(["https://a.example/1"])
      }

      serve(routes)
      assert :updated = Fediverse.refresh_counts(post)

      serve(routes, seen: self())
      Fediverse.refresh_counts(Repo.get!(RemotePost, post.id))

      assert_received {:asked, _object}
      refute_received {:asked, ^others}
    end

    test "an unreachable collection is a strike, and the stored figure stands" do
      {post, _user} = followed_post()
      others = post.object_uri <> "/replies?only_other_accounts=true&page=true"

      serve(%{
        post.object_uri => object(post, %{"replies" => replies_collection(post, [], others)}),
        others => page(["https://a.example/1", "https://b.example/2"])
      })

      assert :updated = Fediverse.refresh_counts(post)

      # The page goes away, the object stays. Backdated so the ladder is due.
      Repo.update_all(from(p in RemotePost, where: p.id == ^post.id),
        set: [replies_checked_at: DateTime.add(DateTime.utc_now(:second), -3600)]
      )

      serve(%{
        post.object_uri => object(post, %{"replies" => replies_collection(post, [], others)})
      })

      Fediverse.refresh_counts(Repo.get!(RemotePost, post.id))

      stored = Repo.get!(RemotePost, post.id)
      assert stored.replies_count == 2
      assert stored.replies_failures == 1
    end

    test "the count reaches every open page like the other two figures" do
      {post, _user} = followed_post()
      others = post.object_uri <> "/replies?only_other_accounts=true&page=true"

      serve(%{
        post.object_uri => object(post, %{"replies" => replies_collection(post, [], others)}),
        others => page(["https://a.example/1"])
      })

      Fediverse.subscribe_counts()
      assert :updated = Fediverse.refresh_counts(post)

      assert_received {:fediverse_counts, :remote_post, _id, %{replies: 1, likes: 28}}
    end
  end

  describe "an origin that serves no figures at all" do
    # flipboard.com, 19 % of everything this installation caches: `likes`,
    # `shares` and `replies` are all absent, and 0 of its 1.478 stored posts
    # had ever carried a figure — while it held 1.026 of the 2.627 objects on
    # the ladder.
    test "leaves the ladder after one ask, without taking a strike" do
      {post, _user} = followed_post()
      serve(%{post.object_uri => object(post) |> Map.drop(["likes", "shares"])})

      assert :unchanged = Fediverse.refresh_counts(post)

      stored = Repo.get!(RemotePost, post.id)
      assert stored.counts_absent
      # Not a failure: the server answered, and answered correctly.
      assert stored.counts_failures == 0
      refute stored.id in Enum.map(Fediverse.due_for_counts(50), & &1.id)
    end

    test "an origin serving one of the three stays on the ladder" do
      {post, _user} = followed_post()
      serve(%{post.object_uri => object(post) |> Map.drop(["shares"])})

      assert :updated = Fediverse.refresh_counts(post)
      refute Repo.get!(RemotePost, post.id).counts_absent
    end
  end

  describe "reading the answers" do
    # One answer on some third server, with the actor document a card needs in
    # order to name who wrote it. Neither host is ours and neither is the
    # origin's, which is the ordinary case: a thread of 60 answers on
    # mastodon.social listed authors on nine other hosts.
    defp answer(host, parent, text) do
      actor = "https://#{host}/users/somebody"
      uri = "https://#{host}/notes/#{System.unique_integer([:positive])}"

      {uri,
       %{
         uri => %{
           "id" => uri,
           "type" => "Note",
           "attributedTo" => actor,
           "content" => "<p>#{text}</p>",
           "inReplyTo" => parent.object_uri,
           "to" => ["https://www.w3.org/ns/activitystreams#Public"],
           "published" => "2026-09-06T12:00:00Z"
         },
         actor => %{
           "id" => actor,
           "type" => "Person",
           "inbox" => actor <> "/inbox",
           "preferredUsername" => "somebody",
           "name" => "Somebody"
         }
       }}
    end

    defp thread(post, answers) do
      others = post.object_uri <> "/replies?only_other_accounts=true&page=true"
      {uris, docs} = Enum.unzip(answers)

      routes =
        Enum.reduce(docs, %{}, &Map.merge(&2, &1))
        |> Map.merge(%{
          post.object_uri => object(post, %{"replies" => replies_collection(post, [], others)}),
          others => page(uris)
        })

      {uris, routes}
    end

    test "fetches the answers and keeps each one as thread context" do
      {post, user} = followed_post()

      {[first, second], routes} =
        thread(post, [
          answer("a.example", post, "Nimm Mint."),
          answer("b.example", post, "Oder Fedora.")
        ])

      serve(routes)

      assert {:ok, %{replies: [one, two], pending: []}} =
               Fediverse.fetch_thread_replies(user, post)

      assert one.object_uri == first
      assert two.object_uri == second
      assert one.content_text == "Nimm Mint."
      # Stored as ordinary cached posts, which is what gives them a card and an
      # action bar — and flagged, which is what keeps them off the listings.
      assert Repo.get_by!(RemotePost, object_uri: first).thread_context
      assert one.remote_account.handle == "somebody"
    end

    test "an answer already stored costs no request at all" do
      {post, user} = followed_post()
      {[uri], routes} = thread(post, [answer("a.example", post, "Nimm Mint.")])

      serve(routes)
      assert {:ok, %{replies: [_one]}} = Fediverse.fetch_thread_replies(user, post)

      serve(routes, seen: self())
      assert {:ok, %{replies: [one]}} = Fediverse.fetch_thread_replies(user, post)
      assert one.object_uri == uri

      # The collection is walked again (the thread may have grown), the answer
      # itself is not re-fetched.
      refute_received {:asked, ^uri}
    end

    test "the leftovers are handed back so a second press walks nothing again" do
      {post, user} = followed_post()

      answers = for n <- 1..12, do: answer("a.example", post, "Antwort #{n}")
      {uris, routes} = thread(post, answers)
      serve(routes)

      assert {:ok, %{replies: first_ten, pending: pending}} =
               Fediverse.fetch_thread_replies(user, post)

      assert length(first_ten) == 10
      assert length(pending) == 2

      assert {:ok, %{replies: rest, pending: []}} =
               Fediverse.fetch_thread_replies(user, post, pending: pending)

      assert Enum.map(rest, & &1.object_uri) == Enum.take(uris, -2)
    end

    test "an origin that serves no replies collection says so instead of guessing" do
      {post, user} = followed_post()
      serve(%{post.object_uri => object(post)})

      assert {:error, :unavailable} = Fediverse.fetch_thread_replies(user, post)
    end

    test "the hourly budget refuses rather than letting one member walk the fediverse" do
      {post, user} = followed_post()
      {_uris, routes} = thread(post, [answer("a.example", post, "Nimm Mint.")])
      serve(routes)

      Application.put_env(:vutuv, :fediverse_thread_fetch_limit, 1)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_thread_fetch_limit) end)

      assert {:ok, _first} = Fediverse.fetch_thread_replies(user, post)
      assert {:error, :capped} = Fediverse.fetch_thread_replies(user, post)
    end

    test "the stored half paints without asking anybody" do
      {post, user} = followed_post()
      {_uris, routes} = thread(post, [answer("a.example", post, "Nimm Mint.")])
      serve(routes)
      assert {:ok, _fetched} = Fediverse.fetch_thread_replies(user, post)

      serve(%{}, seen: self())
      assert [one] = Fediverse.stored_thread_replies(post, user)
      assert one.content_text == "Nimm Mint."
      refute_received {:asked, _url}
    end
  end

  describe "an answer is not feed material" do
    # An answer stored the way a press stores one, by an author this member
    # follows — the case where the flag is the only thing between a thread
    # answer and somebody's feed.
    defp stored_answer(post, acc) do
      now = DateTime.utc_now(:second)

      Repo.insert!(%RemotePost{
        remote_account_id: acc.id,
        object_uri: "https://#{acc.host}/notes/#{System.unique_integer([:positive])}",
        in_reply_to_uri: post.object_uri,
        content_text: "Nimm Mint.",
        audience: "public",
        kind: "note",
        published_at: now,
        received_at: now,
        expires_at: DateTime.add(now, 86_400),
        thread_context: true
      })
    end

    # The feed hands its rows back as entries, whose ids carry the source's own
    # prefix. Read through one helper so the two halves of the calibration
    # below cannot compare different things.
    defp feed_ids(user) do
      user
      |> Fediverse.feed_remote_posts(20, nil, shape: :posts)
      |> Enum.map(& &1.remote_post.id)
    end

    test "a followed author's answer stays out of the feed" do
      {post, user} = followed_post()
      answering = account("a.example")
      follow(user, answering)
      answer = stored_answer(post, answering)

      refute answer.id in feed_ids(user)
      # Calibration: the very same row without the flag is feed material, so
      # this test fails if the flag stops being read.
      Repo.update_all(from(p in RemotePost, where: p.id == ^answer.id),
        set: [thread_context: false]
      )

      assert answer.id in feed_ids(user)
    end

    test "and off its author's account page" do
      {post, user} = followed_post()
      answering = account("a.example")
      follow(user, answering)
      stored_answer(post, answering)

      assert {[], false} = Fediverse.account_posts(answering, user)
    end

    # The remaining surfaces that list an account's posts. They are here as one
    # test rather than four because the risk they share is a fifth being added
    # without the scope — `RemotePost.timeline_scope/1` is the seam, and this is
    # the list of everything that has to go through it.
    test "and off the page feed, the federated timeline and the tag page" do
      {post, user} = followed_post()
      answering = account("a.example")
      follow(user, answering)
      answer = stored_answer(post, answering)

      page = insert(:organization)

      Repo.insert!(%Follow{
        organization_id: page.id,
        remote_account_id: answering.id,
        state: "accepted",
        follow_activity_id: "https://vutuv.test/#{page.id}/actor#f/#{answering.id}"
      })

      page_ids = page |> Fediverse.organization_feed_remote_posts(20, nil) |> Enum.map(& &1.id)
      refute answer.id in page_ids

      federated = Fediverse.recent_public_remote_posts(limit: 50)
      refute answer.id in Enum.map(federated, & &1.id)

      # A tag page reaches its posts through the hashtag join, which a thread
      # answer never enters — and the query narrows by the flag as well, since
      # this one is a public page.
      tag = insert(:tag)
      Repo.insert!(%RemotePostTag{remote_post_id: answer.id, tag_id: tag.id})

      tagged = tag |> Timeline.remote_posts_query() |> Repo.all()
      refute answer.id in Enum.map(tagged, & &1.id)

      # And it is not counted as one of the account's recent posts in the feed's
      # server bar, which orders the accounts by how busy they have been.
      servers = FeedBand.servers(user)
      assert Enum.find(servers, &(&1.host == "a.example")).posts == 0
    end
  end

  describe "retention" do
    test "an answer lives as long as the post it answers" do
      {post, _user} = followed_post()
      answer = stored_answer(post, account("a.example"))

      # Nobody follows the answer's author, which is the normal case for an
      # answer and exactly what this purge deletes.
      Fediverse.purge_unfollowed_remote_posts()
      assert Repo.get(RemotePost, answer.id)

      # The post it hangs under goes, and it goes with it.
      Repo.delete!(post)
      Fediverse.purge_unfollowed_remote_posts()
      refute Repo.get(RemotePost, answer.id)
    end
  end
end
