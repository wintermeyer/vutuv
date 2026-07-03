defmodule Vutuv.BlueskyTest do
  # Not async: the Req seam and the SSRF resolver live in the application env.
  use Vutuv.DataCase

  alias Vutuv.Bluesky
  alias Vutuv.SocialFeed.Feed
  alias Vutuv.SocialFeed.Post

  @handle "alice.bsky.social"
  @avatar_bytes <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0>>

  defp stub_bluesky(fun) do
    Application.put_env(:vutuv, :bluesky_req_options, plug: fun)
    on_exit(fn -> Application.delete_env(:vutuv, :bluesky_req_options) end)
  end

  # Answers the fetch (getProfile, getAuthorFeed and — when the profile
  # advertises one — the avatar) and reports every request back to the test
  # as `{:req, path, query}`.
  defp serve(items, opts \\ []) do
    test_pid = self()

    profile =
      Map.merge(
        %{
          "did" => "did:plc:abc",
          "handle" => @handle,
          "displayName" => "Alice Displayed",
          "labels" => []
        },
        opts[:profile] || %{}
      )

    avatar = Keyword.get(opts, :avatar, fn conn -> avatar_ok(conn) end)

    stub_bluesky(fn conn ->
      send(test_pid, {:req, conn.request_path, conn.query_string})

      case conn.request_path do
        "/xrpc/app.bsky.actor.getProfile" ->
          Plug.Conn.send_resp(conn, 200, Jason.encode!(profile))

        "/xrpc/app.bsky.feed.getAuthorFeed" ->
          Plug.Conn.send_resp(conn, 200, Jason.encode!(%{"feed" => items}))

        "/img/avatar/alice.jpg" ->
          avatar.(conn)
      end
    end)
  end

  defp avatar_ok(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("image/png")
    |> Plug.Conn.send_resp(200, @avatar_bytes)
  end

  defp override_resolver(fun) do
    original = Application.get_env(:vutuv, :ssrf_resolver)
    Application.put_env(:vutuv, :ssrf_resolver, fun)
    on_exit(fn -> Application.put_env(:vutuv, :ssrf_resolver, original) end)
  end

  # One getAuthorFeed item; `attrs` override the post's record, `opts` add
  # item-level parts (a repost/pin `reason`, post `labels`, another rkey).
  defp item(record_attrs \\ %{}, opts \\ []) do
    record =
      Map.merge(
        %{
          "$type" => "app.bsky.feed.post",
          "createdAt" => "2026-07-01T10:30:00.000Z",
          "text" => "Hello sky"
        },
        record_attrs
      )

    entry = %{
      "post" => %{
        "uri" => "at://did:plc:abc/app.bsky.feed.post/" <> Keyword.get(opts, :rkey, "3abc"),
        "author" => %{"did" => "did:plc:abc", "handle" => @handle},
        "record" => record,
        "labels" => Keyword.get(opts, :labels, [])
      }
    }

    case Keyword.get(opts, :reason) do
      nil -> entry
      reason -> Map.put(entry, "reason", reason)
    end
  end

  describe "fetch_posts/1" do
    test "fetches the profile then the author feed and parses it" do
      serve([
        item(%{"text" => "First post"}, rkey: "3one"),
        item(%{"text" => "Second post", "createdAt" => "2026-06-30T08:00:00.000Z"}, rkey: "3two")
      ])

      assert {:ok, %Feed{} = feed} = Bluesky.fetch_posts(@handle)

      assert feed.name == "Alice Displayed"
      assert feed.handle == @handle
      assert feed.url == "https://bsky.app/profile/#{@handle}"
      # No avatar advertised -> nil (and no third request).
      assert feed.avatar == nil

      assert [one, two] = feed.posts
      assert %Post{id: "3one"} = one
      assert one.url == "https://bsky.app/profile/#{@handle}/post/3one"
      assert one.text == "First post"
      assert one.created_at == ~U[2026-07-01 10:30:00.000Z]
      assert two.id == "3two"

      assert_receive {:req, "/xrpc/app.bsky.actor.getProfile", "actor=" <> _}
      assert_receive {:req, "/xrpc/app.bsky.feed.getAuthorFeed", query}
      assert query =~ "actor=alice.bsky.social"
      assert query =~ "filter=posts_no_replies"
      refute_receive {:req, _, _}
    end

    test "an uppercase or @-prefixed stored handle still fetches (normalized)" do
      serve([item()])

      assert {:ok, %Feed{handle: @handle}} = Bluesky.fetch_posts("@Alice.bsky.SOCIAL")
      assert_receive {:req, "/xrpc/app.bsky.actor.getProfile", "actor=alice.bsky.social"}
    end

    test "skips reposts, pins, labeled and text-less posts, keeps at most three" do
      serve([
        item(%{"text" => "boosted"},
          rkey: "3re",
          reason: %{"$type" => "app.bsky.feed.defs#reasonRepost"}
        ),
        item(%{"text" => "pinned"},
          rkey: "3pin",
          reason: %{"$type" => "app.bsky.feed.defs#reasonPin"}
        ),
        item(%{"text" => "flagged"},
          rkey: "3flag",
          labels: [%{"src" => "did:plc:mod", "val" => "porn"}]
        ),
        item(%{"text" => ""}, rkey: "3img"),
        item(%{"text" => "bad stamp", "createdAt" => "not a date"}, rkey: "3bad"),
        item(%{"text" => "one"}, rkey: "3a"),
        item(%{"text" => "two"}, rkey: "3b"),
        item(%{"text" => "three"}, rkey: "3c"),
        item(%{"text" => "four"}, rkey: "3d")
      ])

      assert {:ok, %Feed{posts: posts}} = Bluesky.fetch_posts(@handle)
      assert Enum.map(posts, & &1.id) == ["3a", "3b", "3c"]
    end

    test "a missing display name falls back to the handle" do
      serve([item()], profile: %{"displayName" => ""})

      assert {:ok, %Feed{name: @handle}} = Bluesky.fetch_posts(@handle)
    end

    test "runaway text is capped" do
      serve([item(%{"text" => String.duplicate("a", 900)})])

      assert {:ok, %Feed{posts: [post]}} = Bluesky.fetch_posts(@handle)
      assert String.length(post.text) == 500
      assert String.ends_with?(post.text, "…")
    end

    test "an account that hides from logged-out visitors yields an empty feed" do
      # The !no-unauthenticated self-label means "don't show me to signed-out
      # viewers"; the profile card is a public surface, so we honor it — no
      # posts, no avatar fetch, no feed request.
      serve([item()],
        profile: %{
          "labels" => [%{"src" => "did:plc:abc", "val" => "!no-unauthenticated"}],
          "avatar" => "https://cdn.example/img/avatar/alice.jpg"
        }
      )

      assert {:ok, %Feed{posts: [], avatar: nil}} = Bluesky.fetch_posts(@handle)

      assert_receive {:req, "/xrpc/app.bsky.actor.getProfile", _}
      refute_receive {:req, _, _}
    end

    test "an unknown actor (400) is a hard :gone error" do
      stub_bluesky(fn conn ->
        Plug.Conn.send_resp(
          conn,
          400,
          Jason.encode!(%{"error" => "InvalidRequest", "message" => "Profile not found"})
        )
      end)

      assert {:error, :gone} = Bluesky.fetch_posts(@handle)
    end

    test "server trouble is transient: 5xx, bad JSON, oversized body, raised transport" do
      stub_bluesky(fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
      assert {:error, :transient} = Bluesky.fetch_posts(@handle)

      stub_bluesky(fn conn -> Plug.Conn.send_resp(conn, 200, "not json") end)
      assert {:error, :transient} = Bluesky.fetch_posts(@handle)

      stub_bluesky(fn conn ->
        Plug.Conn.send_resp(conn, 200, String.duplicate("a", 2_000_001))
      end)

      assert {:error, :transient} = Bluesky.fetch_posts(@handle)

      stub_bluesky(fn _conn -> raise "connection refused" end)
      assert {:error, :transient} = Bluesky.fetch_posts(@handle)
    end

    test "a malformed handle is :gone and never touches the network" do
      test_pid = self()

      stub_bluesky(fn conn ->
        send(test_pid, {:req, conn.request_path, conn.query_string})
        Plug.Conn.send_resp(conn, 200, "{}")
      end)

      # No dot (not a domain), an injected path, a Mastodon-style handle.
      assert {:error, :gone} = Bluesky.fetch_posts("nodots")
      assert {:error, :gone} = Bluesky.fetch_posts("alice.bsky.social/../evil")
      assert {:error, :gone} = Bluesky.fetch_posts("alice@example.social")
      refute_receive {:req, _, _}
    end
  end

  describe "the account avatar" do
    test "an advertised avatar arrives server-fetched as a data URI" do
      serve([item()], profile: %{"avatar" => "https://cdn.example/img/avatar/alice.jpg"})

      assert {:ok, %Feed{} = feed} = Bluesky.fetch_posts(@handle)
      assert feed.avatar == "data:image/png;base64," <> Base.encode64(@avatar_bytes)
      assert_receive {:req, "/img/avatar/alice.jpg", _}
    end

    test "avatar problems mean no avatar, never a failed feed" do
      serve([item()],
        profile: %{"avatar" => "https://cdn.example/img/avatar/alice.jpg"},
        avatar: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("text/html")
          |> Plug.Conn.send_resp(200, "<html>gotcha</html>")
        end
      )

      assert {:ok, %Feed{avatar: nil, posts: [_]}} = Bluesky.fetch_posts(@handle)
    end

    test "a non-https avatar URL is never requested" do
      serve([item()], profile: %{"avatar" => "http://cdn.example/img/avatar/alice.jpg"})

      assert {:ok, %Feed{avatar: nil}} = Bluesky.fetch_posts(@handle)

      assert_receive {:req, "/xrpc/app.bsky.actor.getProfile", _}
      assert_receive {:req, "/xrpc/app.bsky.feed.getAuthorFeed", _}
      refute_receive {:req, _, _}
    end

    test "an avatar host resolving to an internal address is never requested" do
      override_resolver(fn host, _family ->
        if host == ~c"internal.example" do
          {:ok, [{127, 0, 0, 1}]}
        else
          {:ok, [{93, 184, 216, 34}]}
        end
      end)

      serve([item()], profile: %{"avatar" => "https://internal.example/img/avatar/alice.jpg"})

      assert {:ok, %Feed{avatar: nil}} = Bluesky.fetch_posts(@handle)

      assert_receive {:req, "/xrpc/app.bsky.actor.getProfile", _}
      assert_receive {:req, "/xrpc/app.bsky.feed.getAuthorFeed", _}
      refute_receive {:req, _, _}
    end
  end
end
