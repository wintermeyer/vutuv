defmodule Vutuv.SocialFeedTest do
  # Not async: the per-provider feature flags live in the application env.
  use Vutuv.DataCase

  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.SocialFeed

  @mastodon_handle "alice@example.social"
  @bluesky_handle "alice.bsky.social"

  defp mastodon_account(attrs \\ []) do
    insert(
      :social_media_account,
      Keyword.merge(
        [provider: "Mastodon", value: @mastodon_handle, user: insert_activated_user()],
        attrs
      )
    )
  end

  defp bluesky_account(attrs \\ []) do
    insert(
      :social_media_account,
      Keyword.merge(
        [provider: "Bluesky", value: @bluesky_handle, user: insert_activated_user()],
        attrs
      )
    )
  end

  defp enable(flag) do
    Application.put_env(:vutuv, flag, true)
    on_exit(fn -> Application.put_env(:vutuv, flag, false) end)
  end

  describe "record_result/3 backoff ladder" do
    test "a transient failure schedules the first 15-minute retry" do
      account = mastodon_account()

      assert {:retry_in_minutes, 15} =
               SocialFeed.record_result("Mastodon", @mastodon_handle, {:error, :transient})

      account = Repo.get!(SocialMediaAccount, account.id)
      assert account.fetch_failures == 1
      assert account.fetch_disabled_at == nil
      assert_in_delta DateTime.diff(account.fetch_retry_at, DateTime.utc_now()), 15 * 60, 5
    end

    test "consecutive failures walk 15/30/60/360/720/1440/2880 minutes" do
      account = bluesky_account()

      expected = [15, 30, 60, 360, 720, 1440, 2880]

      for {minutes, round} <- Enum.with_index(expected, 1) do
        assert {:retry_in_minutes, ^minutes} =
                 SocialFeed.record_result("Bluesky", @bluesky_handle, {:error, :transient})

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

      assert :disabled =
               SocialFeed.record_result("Mastodon", @mastodon_handle, {:error, :transient})

      account = Repo.get!(SocialMediaAccount, account.id)
      assert %DateTime{} = account.fetch_disabled_at
    end

    test "a hard :gone error deactivates immediately" do
      account = mastodon_account()

      assert :disabled = SocialFeed.record_result("Mastodon", @mastodon_handle, {:error, :gone})

      account = Repo.get!(SocialMediaAccount, account.id)
      assert %DateTime{} = account.fetch_disabled_at
    end

    test "success resets the fetch state" do
      account = mastodon_account()

      retry_at = DateTime.add(DateTime.utc_now(:second), 3600)

      Repo.update_all(SocialMediaAccount,
        set: [fetch_failures: 3, fetch_retry_at: retry_at, fetch_disabled_at: retry_at]
      )

      assert :reset = SocialFeed.record_result("Mastodon", @mastodon_handle, {:ok, []})

      account = Repo.get!(SocialMediaAccount, account.id)
      assert account.fetch_failures == 0
      assert account.fetch_retry_at == nil
      assert account.fetch_disabled_at == nil
    end

    test "the fetch state is scoped to the provider, not just the handle" do
      # Same stored value under two providers (contrived, but the DB allows
      # it — the unique index is on (value, provider)): recording a Bluesky
      # failure must never walk the Mastodon row's ladder.
      mastodon = mastodon_account(value: "shared.example")
      bluesky = bluesky_account(value: "shared.example")

      assert {:retry_in_minutes, 15} =
               SocialFeed.record_result("Bluesky", "shared.example", {:error, :transient})

      assert Repo.get!(SocialMediaAccount, mastodon.id).fetch_failures == 0
      assert Repo.get!(SocialMediaAccount, bluesky.id).fetch_failures == 1
    end

    test "an unknown handle records nothing but still classifies" do
      assert {:retry_in_minutes, 15} =
               SocialFeed.record_result("Mastodon", "ghost@nowhere.example", {:error, :transient})

      assert :disabled =
               SocialFeed.record_result("Mastodon", "ghost@nowhere.example", {:error, :gone})

      assert :reset = SocialFeed.record_result("Mastodon", "ghost@nowhere.example", {:ok, []})
    end
  end

  describe "fetch gating" do
    test "fetchable?/1 honors the retry window and permanent deactivation" do
      account = mastodon_account()
      assert SocialFeed.fetchable?(account)

      future = DateTime.add(DateTime.utc_now(:second), 600)
      past = DateTime.add(DateTime.utc_now(:second), -600)

      refute SocialFeed.fetchable?(%{account | fetch_retry_at: future})
      assert SocialFeed.fetchable?(%{account | fetch_retry_at: past})
      refute SocialFeed.fetchable?(%{account | fetch_disabled_at: past})
    end

    test "request_posts/1 is a no-op while the provider's feature flag is off" do
      # config/test.exs turns both provider flags off.
      assert SocialFeed.request_posts(mastodon_account()) == :ignored
      assert SocialFeed.request_posts(bluesky_account()) == :ignored
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

    test "accounts_of/1 lists every enabled provider's accounts, others excluded" do
      enable(:fetch_mastodon_posts)
      enable(:fetch_bluesky_posts)

      user = insert_activated_user()
      insert(:social_media_account, provider: "GitHub", value: "octo", user: user)

      mastodon =
        insert(:social_media_account, provider: "Mastodon", value: @mastodon_handle, user: user)

      bluesky =
        insert(:social_media_account, provider: "Bluesky", value: @bluesky_handle, user: user)

      loaded = Repo.preload(user, :social_media_accounts)

      assert Enum.map(SocialFeed.accounts_of(loaded), & &1.id) |> Enum.sort() ==
               Enum.sort([mastodon.id, bluesky.id])

      # A provider whose flag is off drops out without touching the others.
      Application.put_env(:vutuv, :fetch_bluesky_posts, false)
      assert Enum.map(SocialFeed.accounts_of(loaded), & &1.id) == [mastodon.id]

      assert SocialFeed.accounts_of(Repo.preload(insert_activated_user(), :social_media_accounts)) ==
               []
    end
  end
end
