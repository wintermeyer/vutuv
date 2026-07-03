defmodule Vutuv.SocialFeed.CacheTest do
  # Not async: the Req seams live in the application env, and the cache's
  # GenServer + fetch tasks need the shared SQL Sandbox connection.
  use Vutuv.DataCase

  import ExUnit.CaptureLog

  alias Vutuv.SocialFeed.Cache
  alias Vutuv.SocialFeed.Feed
  alias Vutuv.SocialFeed.Post

  @handle "alice@example.social"
  @key {"Mastodon", @handle}

  defp start_cache(opts \\ []) do
    table = :"feed_cache_test_#{System.unique_integer([:positive])}"
    start_supervised!({Cache, Keyword.merge([name: nil, table: table], opts)})
  end

  defp stub_mastodon(fun) do
    Application.put_env(:vutuv, :mastodon_req_options, plug: fun)
    on_exit(fn -> Application.delete_env(:vutuv, :mastodon_req_options) end)
  end

  # Serves the lookup + statuses pair, reporting every request as
  # `{:req, path, plug_pid}` — the plug runs inside the fetch task, so
  # `plug_pid` lets a test hold that task open (`hold: true` blocks the
  # lookup until the test sends `:go`).
  defp serve(opts \\ []) do
    test_pid = self()
    hold? = Keyword.get(opts, :hold, false)

    stub_mastodon(fn conn ->
      send(test_pid, {:req, conn.request_path, self()})
      respond(conn, hold?)
    end)
  end

  defp respond(%{request_path: "/api/v1/accounts/lookup"} = conn, hold?) do
    if hold? do
      receive do
        :go -> :ok
      end
    end

    Plug.Conn.send_resp(conn, 200, Jason.encode!(%{"id" => "42"}))
  end

  defp respond(%{request_path: "/api/v1/accounts/42/statuses"} = conn, _hold?) do
    Plug.Conn.send_resp(
      conn,
      200,
      Jason.encode!([
        %{
          "id" => "1",
          "created_at" => "2026-07-01T10:30:00.000Z",
          "content" => "<p>Hello</p>",
          "url" => "https://example.social/@alice/1",
          "visibility" => "public",
          "sensitive" => false,
          "spoiler_text" => ""
        }
      ])
    )
  end

  test "a miss fetches, notifies the waiter, and fills the table" do
    cache = start_cache()
    serve()

    Cache.request("Mastodon", @handle, self(), cache)

    assert_receive {:social_feed_posts, "Mastodon", @handle,
                    {:ok, %Feed{posts: [%Post{id: "1", text: "Hello"}]}}}

    assert {:ok, %Feed{posts: [%Post{id: "1"}]}} = Cache.lookup(@key, table_of(cache))
  end

  test "the provider half of the key dispatches to that provider's client" do
    cache = start_cache()
    test_pid = self()

    Application.put_env(:vutuv, :bluesky_req_options,
      plug: fn conn ->
        send(test_pid, {:bluesky_req, conn.request_path})
        respond_bluesky(conn)
      end
    )

    on_exit(fn -> Application.delete_env(:vutuv, :bluesky_req_options) end)

    Cache.request("Bluesky", "alice.bsky.social", self(), cache)

    assert_receive {:social_feed_posts, "Bluesky", "alice.bsky.social",
                    {:ok, %Feed{posts: [%Post{text: "Hello sky"}]}}}

    assert_receive {:bluesky_req, "/xrpc/app.bsky.actor.getProfile"}
    assert_receive {:bluesky_req, "/xrpc/app.bsky.feed.getAuthorFeed"}

    # The two providers cache under distinct keys.
    assert Cache.lookup({"Mastodon", "alice.bsky.social"}, table_of(cache)) == :miss
    assert {:ok, %Feed{}} = Cache.lookup({"Bluesky", "alice.bsky.social"}, table_of(cache))
  end

  defp respond_bluesky(%{request_path: "/xrpc/app.bsky.actor.getProfile"} = conn) do
    Plug.Conn.send_resp(
      conn,
      200,
      Jason.encode!(%{"did" => "did:plc:abc", "handle" => "alice.bsky.social", "labels" => []})
    )
  end

  defp respond_bluesky(%{request_path: "/xrpc/app.bsky.feed.getAuthorFeed"} = conn) do
    Plug.Conn.send_resp(
      conn,
      200,
      Jason.encode!(%{
        "feed" => [
          %{
            "post" => %{
              "uri" => "at://did:plc:abc/app.bsky.feed.post/3abc",
              "author" => %{"did" => "did:plc:abc", "handle" => "alice.bsky.social"},
              "record" => %{"createdAt" => "2026-07-01T10:30:00.000Z", "text" => "Hello sky"},
              "labels" => []
            }
          }
        ]
      })
    )
  end

  test "single-flight: concurrent requests for one account share exactly one fetch" do
    cache = start_cache()
    serve(hold: true)

    # First request starts the fetch; the plug now blocks inside its task.
    Cache.request("Mastodon", @handle, self(), cache)
    assert_receive {:req, "/api/v1/accounts/lookup", task_pid}

    # Two more misses for the same account while the fetch is in flight: they
    # must join the waiter list, never start a second fetch.
    Cache.request("Mastodon", @handle, self(), cache)
    Cache.request("Mastodon", @handle, self(), cache)
    _ = :sys.get_state(cache)

    send(task_pid, :go)

    # Every waiter is notified from the one result...
    for _ <- 1..3 do
      assert_receive {:social_feed_posts, "Mastodon", @handle,
                      {:ok, %Feed{posts: [%Post{id: "1"}]}}}
    end

    # ...and the wire saw exactly one lookup + statuses pair.
    assert_receive {:req, "/api/v1/accounts/42/statuses", _}
    refute_receive {:req, _, _}
  end

  test "a fresh entry answers without touching the network" do
    cache = start_cache()
    serve()

    Cache.request("Mastodon", @handle, self(), cache)
    assert_receive {:social_feed_posts, "Mastodon", @handle, {:ok, _}}
    assert_receive {:req, "/api/v1/accounts/lookup", _}
    assert_receive {:req, "/api/v1/accounts/42/statuses", _}

    Cache.request("Mastodon", @handle, self(), cache)

    assert_receive {:social_feed_posts, "Mastodon", @handle,
                    {:ok, %Feed{posts: [%Post{id: "1"}]}}}

    refute_receive {:req, _, _}
  end

  test "an expired entry refetches" do
    cache = start_cache(posts_ttl: 0)
    serve()

    Cache.request("Mastodon", @handle, self(), cache)
    assert_receive {:social_feed_posts, "Mastodon", @handle, {:ok, _}}
    assert Cache.lookup(@key, table_of(cache)) == :miss

    Cache.request("Mastodon", @handle, self(), cache)
    assert_receive {:social_feed_posts, "Mastodon", @handle, {:ok, _}}
    assert_receive {:req, "/api/v1/accounts/lookup", _}
    assert_receive {:req, "/api/v1/accounts/42/statuses", _}
    assert_receive {:req, "/api/v1/accounts/lookup", _}
    assert_receive {:req, "/api/v1/accounts/42/statuses", _}
  end

  test "a failure is negatively cached for the backoff window" do
    cache = start_cache()
    test_pid = self()

    stub_mastodon(fn conn ->
      send(test_pid, {:req, conn.request_path, self()})
      Plug.Conn.send_resp(conn, 500, "boom")
    end)

    Cache.request("Mastodon", @handle, self(), cache)
    assert_receive {:social_feed_posts, "Mastodon", @handle, {:error, :transient}}
    assert_receive {:req, "/api/v1/accounts/lookup", _}

    # Within the window the error answers from the cache — the struggling
    # instance is not asked again.
    assert Cache.lookup(@key, table_of(cache)) == {:error, :transient}
    Cache.request("Mastodon", @handle, self(), cache)
    assert_receive {:social_feed_posts, "Mastodon", @handle, {:error, :transient}}
    refute_receive {:req, _, _}
  end

  test "a crashed fetch task still notifies every waiter" do
    cache = start_cache()

    stub_mastodon(fn _conn -> exit(:torn_down) end)

    log =
      capture_log(fn ->
        Cache.request("Mastodon", @handle, self(), cache)
        assert_receive {:social_feed_posts, "Mastodon", @handle, {:error, :transient}}, 1_000
      end)

    assert log =~ "torn_down"

    # The inflight entry is gone: a later request goes through the cache path
    # (negative entry), not a stuck waiter list.
    Cache.request("Mastodon", @handle, self(), cache)
    assert_receive {:social_feed_posts, "Mastodon", @handle, {:error, :transient}}
  end

  test "the sweep drops expired rows; reset drops everything" do
    cache = start_cache(posts_ttl: 0)
    serve()

    Cache.request("Mastodon", @handle, self(), cache)
    assert_receive {:social_feed_posts, "Mastodon", @handle, {:ok, _}}

    table = table_of(cache)
    assert :ets.info(table, :size) == 1

    send(cache, :sweep)
    _ = :sys.get_state(cache)
    assert :ets.info(table, :size) == 0

    Cache.request("Mastodon", @handle, self(), cache)
    assert_receive {:social_feed_posts, "Mastodon", @handle, {:ok, _}}
    assert :ets.info(table, :size) == 1
    assert :ok = Cache.reset(cache)
    assert :ets.info(table, :size) == 0
  end

  defp table_of(cache), do: :sys.get_state(cache).table
end
