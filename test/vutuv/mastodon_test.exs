defmodule Vutuv.MastodonTest do
  # Not async: the Req seam and the SSRF resolver live in the application env.
  use Vutuv.DataCase

  alias Vutuv.Mastodon
  alias Vutuv.Mastodon.Feed
  alias Vutuv.Mastodon.Post
  alias Vutuv.Profiles.SocialMediaAccount

  @handle "alice@example.social"
  @avatar_bytes <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0>>

  defp stub_mastodon(fun) do
    Application.put_env(:vutuv, :mastodon_req_options, plug: fun)
    on_exit(fn -> Application.delete_env(:vutuv, :mastodon_req_options) end)
  end

  # Answers the fetch (lookup, statuses and — when the lookup advertises one —
  # the avatar) and reports every request back to the test as
  # `{:req, path, query}`.
  defp serve(statuses, opts \\ []) do
    test_pid = self()
    lookup = Map.merge(%{"id" => "42", "display_name" => "Alice Displayed"}, opts[:lookup] || %{})
    avatar = Keyword.get(opts, :avatar, fn conn -> avatar_ok(conn) end)

    stub_mastodon(fn conn ->
      send(test_pid, {:req, conn.request_path, conn.query_string})

      case conn.request_path do
        "/api/v1/accounts/lookup" -> Plug.Conn.send_resp(conn, 200, Jason.encode!(lookup))
        "/api/v1/accounts/42/statuses" -> Plug.Conn.send_resp(conn, 200, Jason.encode!(statuses))
        "/avatars/alice.png" -> avatar.(conn)
      end
    end)
  end

  defp avatar_ok(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("image/png")
    |> Plug.Conn.send_resp(200, @avatar_bytes)
  end

  defp with_avatar(lookup_extra \\ %{}) do
    Map.merge(%{"avatar_static" => "https://example.social/avatars/alice.png"}, lookup_extra)
  end

  defp override_resolver(fun) do
    original = Application.get_env(:vutuv, :ssrf_resolver)
    Application.put_env(:vutuv, :ssrf_resolver, fun)
    on_exit(fn -> Application.put_env(:vutuv, :ssrf_resolver, original) end)
  end

  defp status(attrs) do
    Map.merge(
      %{
        "id" => "111",
        "created_at" => "2026-07-01T10:30:00.000Z",
        "content" => "<p>Hello world</p>",
        "url" => "https://example.social/@alice/111",
        "visibility" => "public",
        "sensitive" => false,
        "spoiler_text" => ""
      },
      attrs
    )
  end

  defp mastodon_account(attrs \\ []) do
    insert(
      :social_media_account,
      Keyword.merge([provider: "Mastodon", value: @handle, user: insert_activated_user()], attrs)
    )
  end

  describe "text_content/1" do
    test "strips tags and turns p/br into line breaks" do
      assert Mastodon.text_content("<p>Hello <b>world</b></p><p>Second</p>") ==
               "Hello world\n\nSecond"

      assert Mastodon.text_content("line one<br>line two<br/>line three") ==
               "line one\nline two\nline three"
    end

    test "decodes the entities strip_tags leaves escaped, exactly once" do
      assert Mastodon.text_content("<p>Tom &amp; Jerry &lt;3 &#39;q&#39; &quot;x&quot;</p>") ==
               "Tom & Jerry <3 'q' \"x\""

      # A literal "&amp;" in the source text must not be double-unescaped.
      assert Mastodon.text_content("<p>&amp;amp;</p>") == "&amp;"
    end

    test "neutralizes malicious markup to inert text" do
      assert Mastodon.text_content("<script>alert(1)</script><p>safe</p>") =~ "safe"
      refute Mastodon.text_content("<script>alert(1)</script><p>safe</p>") =~ "<script"
      assert Mastodon.text_content("<img src=x onerror=alert(2)>after") == "after"
      refute Mastodon.text_content(~s(<a href="javascript:x">click</a>)) =~ "javascript:"
    end

    test "trims and caps runaway posts" do
      assert Mastodon.text_content("  <p>hi</p>  ") == "hi"

      long = Mastodon.text_content("<p>" <> String.duplicate("a", 900) <> "</p>")
      assert String.length(long) == 500
      assert String.ends_with?(long, "…")
    end
  end

  describe "fetch_posts/1" do
    test "fetches lookup then statuses and parses the feed" do
      serve([
        status(%{"id" => "1", "content" => "<p>First &amp; foremost</p>"}),
        status(%{"id" => "2", "content" => "<p>Second</p>", "visibility" => "unlisted"})
      ])

      assert {:ok, %Feed{} = feed} = Mastodon.fetch_posts(@handle)

      assert feed.name == "Alice Displayed"
      assert feed.handle == @handle
      # No url in the lookup answer -> built from the handle; no avatar
      # advertised -> nil (and no third request).
      assert feed.url == "https://example.social/@alice"
      assert feed.avatar == nil

      assert [one, two] = feed.posts
      assert %Post{id: "1", url: "https://example.social/@alice/111"} = one
      assert one.text == "First & foremost"
      assert one.created_at == ~U[2026-07-01 10:30:00.000Z]
      assert two.id == "2"

      assert_receive {:req, "/api/v1/accounts/lookup", "acct=alice"}
      assert_receive {:req, "/api/v1/accounts/42/statuses", query}
      assert query =~ "exclude_replies=true"
      assert query =~ "exclude_reblogs=true"
      refute_receive {:req, _, _}
    end

    test "keeps only public and unlisted statuses, at most three" do
      serve([
        status(%{"id" => "1", "visibility" => "private"}),
        status(%{"id" => "2", "visibility" => "direct"}),
        status(%{"id" => "3"}),
        status(%{"id" => "4"}),
        status(%{"id" => "5"}),
        status(%{"id" => "6"})
      ])

      assert {:ok, %Feed{posts: posts}} = Mastodon.fetch_posts(@handle)
      assert Enum.map(posts, & &1.id) == ["3", "4", "5"]
    end

    test "spoilered posts show the spoiler text; sensitive without spoiler is skipped" do
      serve([
        status(%{"id" => "1", "sensitive" => true, "spoiler_text" => "CW: lunch"}),
        status(%{"id" => "2", "sensitive" => true}),
        status(%{"id" => "3"})
      ])

      assert {:ok, %Feed{posts: [one, three]}} = Mastodon.fetch_posts(@handle)
      assert one.text == "CW: lunch"
      assert three.id == "3"
    end

    test "skips media-only posts and unparseable timestamps" do
      serve([
        status(%{"id" => "1", "content" => ""}),
        status(%{"id" => "2", "created_at" => "not a date"}),
        status(%{"id" => "3"})
      ])

      assert {:ok, %Feed{posts: [%Post{id: "3"}]}} = Mastodon.fetch_posts(@handle)
    end

    test "a 404 lookup is a hard :gone error" do
      stub_mastodon(fn conn -> Plug.Conn.send_resp(conn, 404, "{}") end)
      assert {:error, :gone} = Mastodon.fetch_posts(@handle)
    end

    test "server trouble is transient: 5xx, bad JSON, oversized body, raised transport" do
      stub_mastodon(fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
      assert {:error, :transient} = Mastodon.fetch_posts(@handle)

      stub_mastodon(fn conn -> Plug.Conn.send_resp(conn, 200, "not json") end)
      assert {:error, :transient} = Mastodon.fetch_posts(@handle)

      stub_mastodon(fn conn ->
        Plug.Conn.send_resp(conn, 200, String.duplicate("a", 2_000_001))
      end)

      assert {:error, :transient} = Mastodon.fetch_posts(@handle)

      stub_mastodon(fn _conn -> raise "connection refused" end)
      assert {:error, :transient} = Mastodon.fetch_posts(@handle)
    end

    test "a malformed handle is :gone and never touches the network" do
      test_pid = self()

      stub_mastodon(fn conn ->
        send(test_pid, {:req, conn.request_path, conn.query_string})
        Plug.Conn.send_resp(conn, 200, "[]")
      end)

      assert {:error, :gone} = Mastodon.fetch_posts("no-instance-part")
      assert {:error, :gone} = Mastodon.fetch_posts("user@host:8080")
      refute_receive {:req, _, _}
    end

    test "an instance resolving to an internal address is :gone and never fetched" do
      test_pid = self()
      override_resolver(fn _host, _family -> {:ok, [{127, 0, 0, 1}]} end)

      stub_mastodon(fn conn ->
        send(test_pid, {:req, conn.request_path, conn.query_string})
        Plug.Conn.send_resp(conn, 200, "[]")
      end)

      assert {:error, :gone} = Mastodon.fetch_posts(@handle)
      refute_receive {:req, _, _}
    end
  end

  describe "the account avatar" do
    test "an advertised avatar arrives server-fetched as a data URI" do
      serve([status(%{})], lookup: with_avatar(%{"url" => "https://example.social/@alice"}))

      assert {:ok, %Feed{} = feed} = Mastodon.fetch_posts(@handle)
      assert feed.url == "https://example.social/@alice"
      assert feed.avatar == "data:image/png;base64," <> Base.encode64(@avatar_bytes)
      assert_receive {:req, "/avatars/alice.png", _}
    end

    test "avatar problems mean no avatar, never a failed feed" do
      # Not an image.
      serve([status(%{})],
        lookup: with_avatar(),
        avatar: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("text/html")
          |> Plug.Conn.send_resp(200, "<html>gotcha</html>")
        end
      )

      assert {:ok, %Feed{avatar: nil, posts: [_]}} = Mastodon.fetch_posts(@handle)

      # Oversized.
      serve([status(%{})],
        lookup: with_avatar(),
        avatar: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("image/png")
          |> Plug.Conn.send_resp(200, String.duplicate("a", 1_000_001))
        end
      )

      assert {:ok, %Feed{avatar: nil}} = Mastodon.fetch_posts(@handle)

      # Missing.
      serve([status(%{})],
        lookup: with_avatar(),
        avatar: fn conn -> Plug.Conn.send_resp(conn, 404, "") end
      )

      assert {:ok, %Feed{avatar: nil}} = Mastodon.fetch_posts(@handle)
    end

    test "a non-https avatar URL is never requested" do
      serve([status(%{})],
        lookup: %{"avatar_static" => "http://example.social/avatars/alice.png"}
      )

      assert {:ok, %Feed{avatar: nil}} = Mastodon.fetch_posts(@handle)

      assert_receive {:req, "/api/v1/accounts/lookup", _}
      assert_receive {:req, "/api/v1/accounts/42/statuses", _}
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

      serve([status(%{})],
        lookup: %{"avatar_static" => "https://internal.example/avatars/alice.png"}
      )

      assert {:ok, %Feed{avatar: nil}} = Mastodon.fetch_posts(@handle)

      assert_receive {:req, "/api/v1/accounts/lookup", _}
      assert_receive {:req, "/api/v1/accounts/42/statuses", _}
      refute_receive {:req, _, _}
    end
  end

  describe "record_result/2 backoff ladder" do
    test "a transient failure schedules the first 15-minute retry" do
      account = mastodon_account()

      assert {:retry_in_minutes, 15} = Mastodon.record_result(@handle, {:error, :transient})

      account = Repo.get!(SocialMediaAccount, account.id)
      assert account.fetch_failures == 1
      assert account.fetch_disabled_at == nil
      assert_in_delta DateTime.diff(account.fetch_retry_at, DateTime.utc_now()), 15 * 60, 5
    end

    test "consecutive failures walk 15/30/60/360/720/1440/2880 minutes" do
      account = mastodon_account()

      expected = [15, 30, 60, 360, 720, 1440, 2880]

      for {minutes, round} <- Enum.with_index(expected, 1) do
        assert {:retry_in_minutes, ^minutes} =
                 Mastodon.record_result(@handle, {:error, :transient})

        reloaded = Repo.get!(SocialMediaAccount, account.id)
        assert reloaded.fetch_failures == round
        assert reloaded.fetch_disabled_at == nil

        assert_in_delta DateTime.diff(reloaded.fetch_retry_at, DateTime.utc_now()),
                        minutes * 60,
                        5
      end
    end

    test "the failure after the 48-hour step deactivates the account for good" do
      account = mastodon_account()

      Repo.update_all(SocialMediaAccount, set: [fetch_failures: 7])

      assert :disabled = Mastodon.record_result(@handle, {:error, :transient})

      account = Repo.get!(SocialMediaAccount, account.id)
      assert %DateTime{} = account.fetch_disabled_at
    end

    test "a hard :gone error deactivates immediately" do
      account = mastodon_account()

      assert :disabled = Mastodon.record_result(@handle, {:error, :gone})

      account = Repo.get!(SocialMediaAccount, account.id)
      assert %DateTime{} = account.fetch_disabled_at
    end

    test "success resets the fetch state" do
      account = mastodon_account()

      retry_at = DateTime.add(DateTime.utc_now(:second), 3600)

      Repo.update_all(SocialMediaAccount,
        set: [fetch_failures: 3, fetch_retry_at: retry_at, fetch_disabled_at: retry_at]
      )

      assert :reset = Mastodon.record_result(@handle, {:ok, []})

      account = Repo.get!(SocialMediaAccount, account.id)
      assert account.fetch_failures == 0
      assert account.fetch_retry_at == nil
      assert account.fetch_disabled_at == nil
    end

    test "an unknown handle records nothing but still classifies" do
      assert {:retry_in_minutes, 15} =
               Mastodon.record_result("ghost@nowhere.example", {:error, :transient})

      assert :disabled = Mastodon.record_result("ghost@nowhere.example", {:error, :gone})
      assert :reset = Mastodon.record_result("ghost@nowhere.example", {:ok, []})
    end
  end

  describe "fetch gating" do
    test "fetchable?/1 honors the retry window and permanent deactivation" do
      account = mastodon_account()
      assert Mastodon.fetchable?(account)

      future = DateTime.add(DateTime.utc_now(:second), 600)
      past = DateTime.add(DateTime.utc_now(:second), -600)

      refute Mastodon.fetchable?(%{account | fetch_retry_at: future})
      assert Mastodon.fetchable?(%{account | fetch_retry_at: past})
      refute Mastodon.fetchable?(%{account | fetch_disabled_at: past})
    end

    test "request_posts/1 is a no-op while the feature flag is off" do
      # config/test.exs turns :fetch_mastodon_posts off.
      assert Mastodon.request_posts(mastodon_account()) == :ignored
    end

    test "editing the handle resets the fetch state" do
      account = mastodon_account()

      Repo.update_all(SocialMediaAccount,
        set: [
          fetch_failures: 8,
          fetch_disabled_at: DateTime.utc_now(:second),
          fetch_retry_at: DateTime.utc_now(:second)
        ]
      )

      account = Repo.get!(SocialMediaAccount, account.id)

      {:ok, updated} =
        account
        |> SocialMediaAccount.changeset(%{"value" => "bob@other.example"})
        |> Repo.update()

      assert updated.fetch_failures == 0
      assert updated.fetch_retry_at == nil
      assert updated.fetch_disabled_at == nil

      # An unrelated update (same handle) keeps the state untouched.
      unchanged = SocialMediaAccount.changeset(updated, %{"value" => "bob@other.example"})
      assert Ecto.Changeset.get_change(unchanged, :fetch_failures) == nil
    end

    test "accounts_of/1 lists every Mastodon account, other providers excluded" do
      user = insert_activated_user()
      insert(:social_media_account, provider: "GitHub", value: "octo", user: user)
      one = insert(:social_media_account, provider: "Mastodon", value: @handle, user: user)

      two =
        insert(:social_media_account, provider: "Mastodon", value: "b@other.social", user: user)

      loaded = Repo.preload(user, :social_media_accounts)

      assert Enum.map(Mastodon.accounts_of(loaded), & &1.id) |> Enum.sort() ==
               Enum.sort([one.id, two.id])

      assert Mastodon.accounts_of(Repo.preload(insert_activated_user(), :social_media_accounts)) ==
               []
    end
  end
end
