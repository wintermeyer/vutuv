defmodule Vutuv.CodeStatsTest do
  # Not async: the feature flag lives in the application env, and the
  # end-to-end test shares the sandbox with the fetcher's processes.
  use Vutuv.DataCase

  alias Vutuv.Activity
  alias Vutuv.CodeStats
  alias Vutuv.CodeStats.Fetcher
  alias Vutuv.Profiles.SocialMediaAccount

  @snapshot %{"total_stars" => 42, "followers" => 7, "top_repos" => []}

  defp enable_code_stats do
    Application.put_env(:vutuv, :fetch_code_stats, true)
    on_exit(fn -> Application.put_env(:vutuv, :fetch_code_stats, false) end)
  end

  defp reload(account), do: Repo.get!(SocialMediaAccount, account.id)

  describe "accounts_of/1 and visible_accounts/1" do
    test "picks only the code-forge providers, in order" do
      user = insert(:user)
      github = insert(:social_media_account, provider: "GitHub", value: "octo", user: user)
      insert(:social_media_account, provider: "LinkedIn", value: "octo", user: user)
      gitlab = insert(:social_media_account, provider: "GitLab", value: "octo", user: user)

      user = Repo.preload(user, :social_media_accounts)

      assert Enum.map(CodeStats.accounts_of(user), & &1.id) == [github.id, gitlab.id]
    end

    test "visible_accounts renders only snapshot-carrying accounts, gated on flag and opt-out" do
      user = insert(:user)
      insert(:social_media_account, provider: "GitHub", value: "empty", user: user)

      with_stats =
        insert(:social_media_account,
          provider: "Codeberg",
          value: "full",
          user: user,
          code_stats: @snapshot,
          code_stats_fetched_at: DateTime.utc_now(:second)
        )

      user = Repo.preload(user, :social_media_accounts)

      # Flag off (the test default): nothing renders.
      assert CodeStats.visible_accounts(user) == []

      enable_code_stats()
      assert Enum.map(CodeStats.visible_accounts(user), & &1.id) == [with_stats.id]

      # The member's opt-out wins over everything.
      opted_out = %{user | show_code_stats?: false}
      assert CodeStats.visible_accounts(opted_out) == []
    end
  end

  describe "dormant_since/1" do
    test "recent activity stays quiet; dormancy past four weeks surfaces the date" do
      recent = DateTime.utc_now() |> DateTime.add(-7, :day) |> DateTime.to_iso8601()
      assert CodeStats.dormant_since(recent) == nil

      old_dt = DateTime.add(DateTime.utc_now(), -60, :day)
      assert CodeStats.dormant_since(DateTime.to_iso8601(old_dt)) == DateTime.to_date(old_dt)

      assert CodeStats.dormant_since(nil) == nil
      assert CodeStats.dormant_since("garbage") == nil
    end
  end

  describe "stale?/1" do
    test "true without a snapshot, true past 7 days, false when fresh" do
      assert CodeStats.stale?(%SocialMediaAccount{code_stats_fetched_at: nil})

      eight_days_ago = DateTime.add(DateTime.utc_now(:second), -8, :day)
      assert CodeStats.stale?(%SocialMediaAccount{code_stats_fetched_at: eight_days_ago})

      yesterday = DateTime.add(DateTime.utc_now(:second), -1, :day)
      refute CodeStats.stale?(%SocialMediaAccount{code_stats_fetched_at: yesterday})
    end
  end

  describe "refresh_if_stale/1" do
    test "ignores when the flag is off, the provider is no forge, or the snapshot is fresh" do
      account = %SocialMediaAccount{provider: "GitHub", value: "octo"}
      assert CodeStats.refresh_if_stale(account) == :ignored

      enable_code_stats()
      assert CodeStats.refresh_if_stale(%{account | provider: "LinkedIn"}) == :ignored

      fresh = %{account | code_stats_fetched_at: DateTime.utc_now(:second)}
      assert CodeStats.refresh_if_stale(fresh) == :ignored

      disabled = %{account | fetch_disabled_at: DateTime.utc_now(:second)}
      assert CodeStats.refresh_if_stale(disabled) == :ignored
    end
  end

  describe "record_result/3" do
    test "a success writes the snapshot, clears the backoff and notifies the owner" do
      user = insert(:user)

      account =
        insert(:social_media_account,
          provider: "GitHub",
          value: "octo",
          user: user,
          fetch_failures: 3,
          fetch_retry_at: DateTime.utc_now(:second)
        )

      Activity.subscribe(user.id)

      assert CodeStats.record_result("GitHub", "octo", {:ok, @snapshot}) == :ok
      assert_receive {:code_stats_updated, account_id}
      assert account_id == account.id

      reloaded = reload(account)
      assert reloaded.code_stats == @snapshot
      assert %DateTime{} = reloaded.code_stats_fetched_at
      assert reloaded.fetch_failures == 0
      assert is_nil(reloaded.fetch_retry_at)
    end

    test "transient failures walk the backoff ladder and finally deactivate" do
      account = insert(:social_media_account, provider: "GitLab", value: "octo")

      assert CodeStats.record_result("GitLab", "octo", {:error, :transient}) == :ok
      first = reload(account)
      assert first.fetch_failures == 1
      assert %DateTime{} = first.fetch_retry_at
      assert is_nil(first.fetch_disabled_at)

      # Exhaust the ladder (7 rungs); the 8th failure deactivates for good.
      for _ <- 1..7, do: CodeStats.record_result("GitLab", "octo", {:error, :transient})
      assert %DateTime{} = reload(account).fetch_disabled_at
    end

    test "a hard error deactivates immediately" do
      account = insert(:social_media_account, provider: "Codeberg", value: "octo")

      assert CodeStats.record_result("Codeberg", "octo", {:error, :gone}) == :ok
      assert %DateTime{} = reload(account).fetch_disabled_at
    end
  end

  describe "the changeset resets the snapshot on a handle change" do
    test "editing the value drops code_stats so the new account gets a fresh fetch" do
      account =
        insert(:social_media_account,
          provider: "GitHub",
          value: "old-handle",
          code_stats: @snapshot,
          code_stats_fetched_at: DateTime.utc_now(:second),
          fetch_disabled_at: DateTime.utc_now(:second)
        )

      {:ok, updated} =
        account
        |> SocialMediaAccount.changeset(%{"value" => "new-handle"})
        |> Repo.update()

      assert is_nil(updated.code_stats)
      assert is_nil(updated.code_stats_fetched_at)
      assert is_nil(updated.fetch_disabled_at)
    end
  end

  describe "the fetcher end to end" do
    test "one request fetches, persists and broadcasts; duplicates coalesce" do
      enable_code_stats()
      test_pid = self()

      # The GitHub stub blocks each request until the test releases it, so the
      # duplicate cast provably arrives while the first fetch is in flight.
      Application.put_env(:vutuv, :github_req_options,
        plug: fn conn ->
          send(test_pid, {:req, conn.request_path, self()})

          receive do
            :continue -> :ok
          end

          body =
            case conn.request_path do
              "/users/octo" ->
                %{"followers" => 7, "public_repos" => 1, "created_at" => "2010-01-01T00:00:00Z"}

              "/users/octo/repos" ->
                [
                  %{
                    "name" => "hello",
                    "html_url" => "https://github.com/octo/hello",
                    "description" => "Hi",
                    "language" => "Elixir",
                    "stargazers_count" => 42,
                    "fork" => false,
                    "pushed_at" => "2026-07-01T10:00:00Z"
                  }
                ]
            end

          Plug.Conn.send_resp(conn, 200, Jason.encode!(body))
        end
      )

      on_exit(fn -> Application.delete_env(:vutuv, :github_req_options) end)

      user = insert(:user)
      account = insert(:social_media_account, provider: "GitHub", value: "octo", user: user)
      Activity.subscribe(user.id)

      fetcher = start_supervised!({Fetcher, name: nil})

      Fetcher.request("GitHub", "octo", fetcher)
      # The duplicate while the first fetch hangs in the stub must not start
      # a second fetch (single-flight).
      Fetcher.request("GitHub", "octo", fetcher)

      assert_receive {:req, "/users/octo", blocked}
      send(blocked, :continue)
      assert_receive {:req, "/users/octo/repos", blocked}
      send(blocked, :continue)

      assert_receive {:code_stats_updated, account_id}
      assert account_id == account.id
      refute_receive {:req, "/users/octo", _}, 100

      reloaded = reload(account)
      assert reloaded.code_stats["total_stars"] == 42
      assert reloaded.code_stats["followers"] == 7
      assert reloaded.code_stats["languages"] == ["Elixir"]
      assert [%{"name" => "hello", "stars" => 42}] = reloaded.code_stats["top_repos"]
    end
  end
end
