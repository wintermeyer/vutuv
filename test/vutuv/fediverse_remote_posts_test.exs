defmodule Vutuv.FediverseRemotePostsTest do
  @moduledoc """
  What a followed account posts (issue #1161): what is stored and what is
  dropped, who may read it, the retention and purge paths, and the feed source.

  `async: false` — the inbound caps live in the shared `Vutuv.RateLimiter` ETS
  table, which the SQL sandbox does not roll back.
  """
  use Vutuv.DataCase, async: false

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemoteImage
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Posts

  @actor "https://social.example/users/them"
  @public "https://www.w3.org/ns/activitystreams#Public"
  @followers @actor <> "/followers"
  @picture "https://social.example/media/1.jpg"

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  defp account(attrs \\ []) do
    Repo.insert!(%RemoteAccount{
      actor_uri: attrs[:actor_uri] || @actor,
      host: attrs[:host] || "social.example",
      handle: attrs[:handle] || "them",
      name: attrs[:name] || "Them",
      inbox_uri: "https://social.example/users/them/inbox"
    })
  end

  defp member, do: insert(:activated_user, fediverse_followers?: true)

  defp follow(user, account, state \\ "accepted", muted \\ false) do
    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: state,
      muted: muted,
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#follows/#{account.id}"
    })
  end

  # A Create as the servers out there really send one.
  defp create_activity(overrides \\ %{}) do
    object =
      Map.merge(
        %{
          "id" => "https://social.example/posts/1",
          "type" => "Note",
          "attributedTo" => @actor,
          "content" => "<p>Hello from <b>over here</b>.</p>",
          "url" => "https://social.example/@them/1",
          "published" => "2026-07-20T09:00:00Z",
          "to" => [@public],
          "cc" => [@followers]
        },
        Map.get(overrides, :object, %{})
      )

    Map.merge(
      %{"type" => "Create", "actor" => @actor, "object" => object},
      Map.drop(overrides, [:object])
    )
  end

  describe "record_remote_post/2" do
    test "stores one plain-text row for a followed account's post" do
      user = member()
      acc = account()
      follow(user, acc)

      assert :ok = Fediverse.record_remote_post(create_activity(), @actor)

      assert [post] = Repo.all(RemotePost)
      assert post.remote_account_id == acc.id
      assert post.object_uri == "https://social.example/posts/1"
      assert post.origin_url == "https://social.example/@them/1"
      assert post.audience == "public"
      assert post.kind == "note"
      # Plain text, never HTML: nothing a stranger wrote is rendered raw.
      assert post.content_text == "Hello from over here."
      refute post.content_text =~ "<b>"
      # The author's own stamp is what orders the feed.
      assert DateTime.to_date(post.published_at) == ~D[2026-07-20]
    end

    test "a redelivery stores no second row, and is a skip" do
      user = member()
      acc = account()
      follow(user, acc)

      assert :ok = Fediverse.record_remote_post(create_activity(), @actor)
      # A `:skip`, not a second `:ok`: the row is already here. The distinction
      # is what keeps the delivery from writing this post's pictures twice —
      # against an id that names no row, which raised a foreign-key error and
      # 500ed the inbox for the most ordinary delivery pattern there is (two
      # members following the same account each get their own copy).
      assert :skip = Fediverse.record_remote_post(create_activity(), @actor)

      assert Repo.aggregate(RemotePost, :count) == 1
    end

    test "a redelivered post with a picture does not raise, and keeps one picture" do
      user = member()
      acc = account()
      follow(user, acc)

      with_picture = %{
        object: %{
          "attachment" => [
            %{"type" => "Document", "mediaType" => "image/jpeg", "url" => @picture}
          ]
        }
      }

      assert :ok = Fediverse.record_remote_post(create_activity(with_picture), @actor)
      assert :skip = Fediverse.record_remote_post(create_activity(with_picture), @actor)

      assert Repo.aggregate(RemoteImage, :count) == 1
    end

    test "a post that is only a picture is stored, with no words put in the author's mouth" do
      user = member()
      acc = account()
      follow(user, acc)

      activity =
        create_activity(%{
          object: %{
            "content" => "",
            "attachment" => [
              %{"type" => "Document", "mediaType" => "image/jpeg", "url" => @picture}
            ]
          }
        })

      assert :ok = Fediverse.record_remote_post(activity, @actor)

      # Empty, deliberately: the inbox has no locale, so any sentence built
      # here would freeze the English one into the column for every German
      # reader — and into the search text and the muted-word filter with it.
      assert [post] = Repo.all(RemotePost)
      assert post.content_text == ""
      assert Repo.aggregate(RemoteImage, :count) == 1
    end

    test "a stranger's post is dropped, and so is one from an unanswered follow" do
      acc = account()

      # Nobody follows them at all.
      assert :skip = Fediverse.record_remote_post(create_activity(), @actor)

      # Somebody asked to, and that server has not answered. A request is not a
      # relationship, so it does not open the door either.
      follow(member(), acc, "requested")
      assert :skip = Fediverse.record_remote_post(create_activity(), @actor)

      assert Repo.aggregate(RemotePost, :count) == 0
    end

    test "reads the three audiences and stores nothing narrower" do
      user = member()
      acc = account()
      follow(user, acc)

      cases = [
        {%{"to" => [@public], "cc" => [@followers]}, "public"},
        {%{"to" => [@followers], "cc" => [@public]}, "unlisted"},
        {%{"to" => [@followers], "cc" => []}, "followers"}
      ]

      for {{addressing, expected}, n} <- Enum.with_index(cases) do
        object = Map.merge(addressing, %{"id" => "https://social.example/posts/a#{n}"})
        assert :ok = Fediverse.record_remote_post(create_activity(%{object: object}), @actor)

        assert Repo.get_by!(RemotePost, object_uri: "https://social.example/posts/a#{n}").audience ==
                 expected
      end

      # A direct message to a third party is nobody here's business.
      direct = %{
        "id" => "https://social.example/posts/dm",
        "to" => ["https://social.example/users/someone"],
        "cc" => []
      }

      assert :skip = Fediverse.record_remote_post(create_activity(%{object: direct}), @actor)
      refute Repo.get_by(RemotePost, object_uri: "https://social.example/posts/dm")
    end

    test "keeps the author's own thread and drops a reply into somebody else's" do
      user = member()
      acc = account()
      follow(user, acc)

      assert :ok = Fediverse.record_remote_post(create_activity(), @actor)

      continuation = %{
        "id" => "https://social.example/posts/2",
        "inReplyTo" => "https://social.example/posts/1"
      }

      assert :ok = Fediverse.record_remote_post(create_activity(%{object: continuation}), @actor)

      # A reply under a stranger's post drags a third party's conversation into
      # our storage for the sake of one half of it.
      into_a_stranger = %{
        "id" => "https://social.example/posts/3",
        "inReplyTo" => "https://elsewhere.example/posts/99"
      }

      assert :skip =
               Fediverse.record_remote_post(create_activity(%{object: into_a_stranger}), @actor)

      assert Repo.aggregate(RemotePost, :count) == 2
    end

    test "a poll keeps its options and is marked as one" do
      user = member()
      acc = account()
      follow(user, acc)

      poll = %{
        "id" => "https://social.example/posts/poll",
        "type" => "Question",
        "content" => "<p>Tea or coffee?</p>",
        "oneOf" => [
          %{"type" => "Note", "name" => "Tea"},
          %{"type" => "Note", "name" => "Coffee"}
        ]
      }

      assert :ok = Fediverse.record_remote_post(create_activity(%{object: poll}), @actor)

      post = Repo.get_by!(RemotePost, object_uri: "https://social.example/posts/poll")
      assert RemotePost.question?(post)
      assert post.content_text =~ "Tea or coffee?"
      assert post.content_text =~ "• Tea"
      assert post.content_text =~ "• Coffee"
    end

    test "a future publication date cannot pin a post to the top of a feed" do
      user = member()
      acc = account()
      follow(user, acc)

      future = %{"id" => "https://social.example/posts/f", "published" => "2099-01-01T00:00:00Z"}
      assert :ok = Fediverse.record_remote_post(create_activity(%{object: future}), @actor)

      post = Repo.get_by!(RemotePost, object_uri: "https://social.example/posts/f")
      assert DateTime.compare(post.published_at, DateTime.utc_now()) != :gt
    end

    test "a post with nothing left once the markup is gone is not stored" do
      user = member()
      acc = account()
      follow(user, acc)

      empty = %{"id" => "https://social.example/posts/e", "content" => "<p></p>"}
      assert :skip = Fediverse.record_remote_post(create_activity(%{object: empty}), @actor)
      assert Repo.aggregate(RemotePost, :count) == 0
    end

    test "the content warning and the sensitive flag are kept apart" do
      user = member()
      acc = account()
      follow(user, acc)

      warned = %{
        "id" => "https://social.example/posts/w",
        "summary" => "Politics",
        "sensitive" => true
      }

      assert :ok = Fediverse.record_remote_post(create_activity(%{object: warned}), @actor)

      post = Repo.get_by!(RemotePost, object_uri: "https://social.example/posts/w")
      assert post.summary == "Politics"
      assert post.sensitive
      assert RemotePost.warned?(post)
    end
  end

  describe "upstream edits and withdrawals" do
    setup do
      user = member()
      acc = account()
      follow(user, acc)
      :ok = Fediverse.record_remote_post(create_activity(), @actor)
      %{user: user, account: acc}
    end

    test "an Update re-reduces the text" do
      edit = %{
        "type" => "Update",
        "object" => %{
          "id" => "https://social.example/posts/1",
          "type" => "Note",
          "content" => "<p>Fixed a typo.</p>",
          "to" => [@public]
        }
      }

      assert :ok = Fediverse.update_remote_post(edit, @actor)

      assert Repo.get_by!(RemotePost, object_uri: "https://social.example/posts/1").content_text ==
               "Fixed a typo."
    end

    test "an Update that narrows past what we may hold deletes the row" do
      narrowed = %{
        "type" => "Update",
        "object" => %{
          "id" => "https://social.example/posts/1",
          "type" => "Note",
          "content" => "<p>Now private.</p>",
          "to" => ["https://social.example/users/someone"],
          "cc" => []
        }
      }

      assert :ok = Fediverse.update_remote_post(narrowed, @actor)
      assert Repo.aggregate(RemotePost, :count) == 0
    end

    test "one server cannot edit or delete another's post" do
      other = "https://elsewhere.example/users/mallory"

      edit = %{
        "type" => "Update",
        "object" => %{
          "id" => "https://social.example/posts/1",
          "type" => "Note",
          "content" => "<p>Hijacked.</p>",
          "to" => [@public]
        }
      }

      assert :ok = Fediverse.update_remote_post(edit, other)
      assert :ok = Fediverse.delete_remote_post(other, "https://social.example/posts/1")

      post = Repo.get_by!(RemotePost, object_uri: "https://social.example/posts/1")
      assert post.content_text == "Hello from over here."
    end

    test "a Delete removes it at once" do
      assert :ok = Fediverse.delete_remote_post(@actor, "https://social.example/posts/1")
      assert Repo.aggregate(RemotePost, :count) == 0
    end
  end

  describe "retention and purges" do
    test "the sweeper deletes everything past its ceiling" do
      user = member()
      acc = account()
      follow(user, acc)
      :ok = Fediverse.record_remote_post(create_activity(), @actor)

      assert Fediverse.expire_due_remote_posts() == 0

      Repo.update_all(RemotePost, set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1)])
      assert Fediverse.expire_due_remote_posts() == 1
      assert Repo.aggregate(RemotePost, :count) == 0
    end

    test "unfollowing drops the cached posts right away" do
      user = member()
      acc = account()
      f = follow(user, acc)
      :ok = Fediverse.record_remote_post(create_activity(), @actor)

      assert :ok = Fediverse.unfollow_remote(user, f.id)

      assert Repo.aggregate(RemotePost, :count) == 0
      # The account row stays: it may still be named elsewhere, and re-resolving
      # it on the next follow would be a needless round trip.
      assert Repo.aggregate(RemoteAccount, :count) == 1
    end

    test "a second follower keeps the cache alive" do
      one = member()
      two = member()
      acc = account()
      f = follow(one, acc)
      follow(two, acc)
      :ok = Fediverse.record_remote_post(create_activity(), @actor)

      assert :ok = Fediverse.unfollow_remote(one, f.id)
      assert Repo.aggregate(RemotePost, :count) == 1
    end

    test "the sweep catches a cache whose follow vanished through a cascade" do
      user = member()
      acc = account()
      follow(user, acc)
      :ok = Fediverse.record_remote_post(create_activity(), @actor)

      # What a member account deletion does: the follow cascades away and
      # nothing calls the purge.
      Repo.delete_all(Follow)

      assert Fediverse.purge_unfollowed_remote_posts() == 1
      assert Repo.aggregate(RemotePost, :count) == 0
    end

    test "blocking the server purges its cached posts with its accounts" do
      user = member()
      acc = account()
      follow(user, acc)
      :ok = Fediverse.record_remote_post(create_activity(), @actor)

      {:ok, {_blocked, purged}} =
        Fediverse.block_instance(%{"host" => "social.example"}, insert(:user, admin?: true))

      assert purged.cached_posts == 1
      assert Repo.aggregate(RemotePost, :count) == 0
    end

    test "a report deletes the copy and logs it without content" do
      user = member()
      acc = account()
      follow(user, acc)
      :ok = Fediverse.record_remote_post(create_activity(), @actor)
      [post] = Repo.all(RemotePost)

      assert :ok = Fediverse.report_remote_post(post.id, user)
      assert Repo.aggregate(RemotePost, :count) == 0

      assert [event] = Fediverse.recent_note_events()
      assert event.action == "reported_post"
      assert event.host == "social.example"
      # The ledger carries no content and no URI by construction.
      refute Map.get(event, :content_text)
      refute event.actor_digest =~ "social.example"
    end
  end

  describe "the feed source" do
    setup do
      user = member()
      acc = account()
      %{user: user, account: acc}
    end

    test "a followed account's public post reaches the follower and nobody else", %{
      user: user,
      account: acc
    } do
      follow(user, acc)
      :ok = Fediverse.record_remote_post(create_activity(), @actor)

      assert [entry] = Fediverse.feed_remote_posts(user, 10, nil)
      assert entry.id == "remote-" <> entry.remote_post.id
      assert entry.post == nil
      assert entry.remote_post.content_text == "Hello from over here."
      assert %RemoteAccount{handle: "them"} = entry.remote_post.remote_account

      assert Fediverse.feed_remote_posts(member(), 10, nil) == []
    end

    test "a followers-only post needs an accepted follow", %{account: acc} do
      accepted = member()
      requested = member()
      follow(accepted, acc)
      follow(requested, acc, "requested")

      private = %{"id" => "https://social.example/posts/p", "to" => [@followers], "cc" => []}
      :ok = Fediverse.record_remote_post(create_activity(%{object: private}), @actor)

      assert [_entry] = Fediverse.feed_remote_posts(accepted, 10, nil)
      assert Fediverse.feed_remote_posts(requested, 10, nil) == []
    end

    test "a muted follow keeps the subscription and leaves the feed", %{user: user, account: acc} do
      follow(user, acc, "accepted", true)
      :ok = Fediverse.record_remote_post(create_activity(), @actor)

      assert Fediverse.feed_remote_posts(user, 10, nil) == []
      assert Fediverse.remote_follow_count(user) == 1
    end

    test "the installation switch empties the source", %{user: user, account: acc} do
      follow(user, acc)
      :ok = Fediverse.record_remote_post(create_activity(), @actor)

      Application.put_env(:vutuv, :fediverse_enabled, false)
      on_exit(fn -> Application.delete_env(:vutuv, :fediverse_enabled) end)

      assert Fediverse.feed_remote_posts(user, 10, nil) == []
    end

    test "the home feed merges them in by publication time", %{user: user, account: acc} do
      follow(user, acc)
      :ok = Fediverse.record_remote_post(create_activity(), @actor)

      page = Posts.feed_page(user)

      assert [entry] = page.entries
      assert Posts.remote_feed_entry?(entry)
      assert entry.remote_post.content_text == "Hello from over here."
    end

    test "an own post and a remote one sort by time, not by source", %{user: user, account: acc} do
      follow(user, acc)
      :ok = Fediverse.record_remote_post(create_activity(), @actor)
      own = Vutuv.PostsHelpers.create_post!(user, %{"body" => "Mine, later."})

      page = Posts.feed_page(user)

      # The remote post is stamped 2026-07-20; the vutuv post was just written.
      assert [first, second] = page.entries
      refute Posts.remote_feed_entry?(first)
      assert first.post.id == own.id
      assert Posts.remote_feed_entry?(second)
    end
  end

  describe "remembering an account (issue #1162)" do
    # The fetched actor document the inbox has in hand once a delivery is
    # verified — the same shape `fetch_remote_actor/2` returns.
    defp actor_doc(uri \\ @actor) do
      %{
        id: uri,
        inbox: uri <> "/inbox",
        shared_inbox: nil,
        preferred_username: "them",
        name: "Them",
        summary: "<p>Schreibt über <b>Züge</b>.</p>",
        public_key_id: nil,
        public_key_pem: "PEM",
        also_known_as: []
      }
    end

    test "keeps what the inbox already read, as plain text" do
      assert :ok = Fediverse.remember_remote_account(actor_doc())

      account = Repo.get_by!(RemoteAccount, actor_uri: @actor)
      assert account.host == "social.example"
      assert account.handle == "them"
      assert account.summary == "Schreibt über Züge."
      refute account.summary =~ "<b>"
    end

    test "a second delivery re-syncs the one row" do
      assert :ok = Fediverse.remember_remote_account(actor_doc())
      assert :ok = Fediverse.remember_remote_account(%{actor_doc() | name: "Renamed"})

      assert Repo.aggregate(RemoteAccount, :count) == 1
      assert Repo.get_by!(RemoteAccount, actor_uri: @actor).name == "Renamed"
    end

    test "an account nothing refers to any more is forgotten" do
      :ok = Fediverse.remember_remote_account(actor_doc())
      assert Repo.aggregate(RemoteAccount, :count) == 1

      # Nothing follows it, it wrote nothing here, nobody's post carries a reply
      # or a reaction from it: "we remember who reacted to your post" must not
      # become a directory of everybody who ever touched this installation.
      assert Fediverse.purge_unreferenced_remote_accounts() == 1
      assert Repo.aggregate(RemoteAccount, :count) == 0
    end

    test "an account somebody follows, or whose words we hold, is kept" do
      :ok = Fediverse.remember_remote_account(actor_doc())
      acc = Repo.get_by!(RemoteAccount, actor_uri: @actor)
      follow(member(), acc)

      assert Fediverse.purge_unreferenced_remote_accounts() == 0
      assert Repo.aggregate(RemoteAccount, :count) == 1
    end
  end

  describe "who an activity concerns" do
    test "a Create from a followed account names the members who follow it" do
      user = member()
      acc = account()
      follow(user, acc)

      # Without this the shared inbox resolves nobody, signs its actor fetch
      # anonymously, and an authorized-fetch server refuses it — losing the post.
      assert [%{id: found}] = Fediverse.inbox_recipients(create_activity(), @actor)
      assert found == user.id
    end
  end
end
