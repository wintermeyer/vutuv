defmodule Vutuv.Profiles.SocialAccountVerificationTest do
  @moduledoc """
  The "this Bluesky account is really mine" proof. Not async: the Req seam and
  the feature flag both live in the application env.
  """
  use Vutuv.DataCase

  alias Vutuv.Profiles.SocialAccountVerification, as: Verification
  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.Repo

  @handle "alice.bsky.social"

  defp enable do
    Application.put_env(:vutuv, :verify_social_accounts, true)
    on_exit(fn -> Application.put_env(:vutuv, :verify_social_accounts, false) end)
  end

  defp stub_bluesky(fun) do
    Application.put_env(:vutuv, :bluesky_req_options, plug: fun)
    on_exit(fn -> Application.delete_env(:vutuv, :bluesky_req_options) end)
  end

  # Serves getProfile with the given bio. Reports each request as {:req, path}
  # so a test can prove no call happened at all.
  defp serve_bio(description) do
    test_pid = self()

    stub_bluesky(fn conn ->
      send(test_pid, {:req, conn.request_path})

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{
          "did" => "did:plc:abc",
          "handle" => @handle,
          "displayName" => "Alice",
          "description" => description,
          "labels" => []
        })
      )
    end)
  end

  defp serve_status(status) do
    test_pid = self()

    stub_bluesky(fn conn ->
      send(test_pid, {:req, conn.request_path})
      Plug.Conn.send_resp(conn, status, "{}")
    end)
  end

  defp bluesky_account(user, handle \\ @handle) do
    insert(:social_media_account, provider: "Bluesky", value: handle, user: user)
  end

  defp profile_url(user), do: VutuvWeb.Endpoint.url() <> "/" <> user.username

  describe "verify/2" do
    setup do
      enable()
      user = insert_activated_user()
      %{user: user, account: bluesky_account(user)}
    end

    test "a bio carrying the vutuv profile URL earns the mark", ctx do
      serve_bio("Developer. Also at #{profile_url(ctx.user)} — say hi!")

      assert {:ok, account} = Verification.verify(ctx.account, ctx.user)
      assert account.verification_method == "bluesky_bio"
      assert account.verified_at
      assert account.last_checked_at
      refute account.grace_deadline_at

      assert_receive {:req, "/xrpc/app.bsky.actor.getProfile"}
    end

    test "a bio without the URL earns nothing", ctx do
      serve_bio("Developer. Nothing to see here.")

      assert {:error, :not_found} = Verification.verify(ctx.account, ctx.user)
      assert Repo.reload(ctx.account).verified_at == nil
    end

    test "another member's profile URL does not count", ctx do
      stranger = insert_activated_user()
      serve_bio("Find me at #{profile_url(stranger)}")

      assert {:error, :not_found} = Verification.verify(ctx.account, ctx.user)
    end

    test "the URL is matched whole, not as a prefix of a longer handle", ctx do
      # A member "alice" must not be verified by a bio linking to "alicexyz".
      serve_bio("Find me at #{profile_url(ctx.user)}xyz")

      assert {:error, :not_found} = Verification.verify(ctx.account, ctx.user)
    end

    test "a network error is transient, not a refusal to ever verify", ctx do
      serve_status(500)
      assert {:error, :unreachable} = Verification.verify(ctx.account, ctx.user)
    end

    test "an unknown actor reads as not found", ctx do
      serve_status(400)
      assert {:error, :not_found} = Verification.verify(ctx.account, ctx.user)
    end

    test "a non-Bluesky provider is unsupported and never touches the network", ctx do
      serve_bio("irrelevant")

      account =
        insert(:social_media_account, provider: "LinkedIn", value: "alice", user: ctx.user)

      assert {:error, :unsupported} = Verification.verify(account, ctx.user)
      refute_receive {:req, _}
    end
  end

  describe "verify/2 with the flag off" do
    test "refuses without calling out — the intranet case" do
      Application.put_env(:vutuv, :verify_social_accounts, false)
      user = insert_activated_user()
      account = bluesky_account(user)

      test_pid = self()
      stub_bluesky(fn conn -> send(test_pid, {:req, conn.request_path}) end)

      assert {:error, :disabled} = Verification.verify(account, user)
      refute_receive {:req, _}
    end
  end

  describe "recheck/1" do
    setup do
      enable()
      user = insert_activated_user()

      account =
        user
        |> bluesky_account()
        |> SocialMediaAccount.verification_changeset(%{
          verification_method: "bluesky_bio",
          verified_at: ~N[2026-07-01 10:00:00],
          last_checked_at: ~N[2026-07-01 10:00:00]
        })
        |> Repo.update!()

      %{user: user, account: Repo.preload(account, :user)}
    end

    test "a proof still in place refreshes the timestamp and keeps the mark", ctx do
      serve_bio("Also at #{profile_url(ctx.user)}")

      assert :ok = Verification.recheck(ctx.account)

      reloaded = Repo.reload(ctx.account)
      assert reloaded.verified_at
      refute reloaded.grace_deadline_at
      assert reloaded.last_checked_at != ~N[2026-07-01 10:00:00]
    end

    test "a vanished proof opens a grace window before the mark drops", ctx do
      serve_bio("I removed the link")

      assert :grace_started = Verification.recheck(ctx.account)
      graced = Repo.reload(ctx.account)
      # Still verified during the window: a bio edited by accident, or a
      # network having a bad day, must not cost the mark immediately.
      assert graced.verified_at
      assert graced.grace_deadline_at

      # A second check inside the window changes nothing but the timestamp.
      assert :in_grace = Verification.recheck(Repo.preload(graced, :user))
      assert Repo.reload(ctx.account).verified_at

      # Once the deadline has passed, the mark goes.
      expired =
        graced
        |> SocialMediaAccount.verification_changeset(%{
          grace_deadline_at: ~N[2026-07-01 10:00:00]
        })
        |> Repo.update!()

      assert :demoted = Verification.recheck(Repo.preload(expired, :user))

      dropped = Repo.reload(ctx.account)
      refute dropped.verified_at
      refute dropped.verification_method
      refute dropped.grace_deadline_at
    end

    test "an unreachable network is not a lost proof", ctx do
      serve_status(500)

      assert :unreachable = Verification.recheck(ctx.account)

      # No grace window opened: we learned nothing about the bio.
      reloaded = Repo.reload(ctx.account)
      assert reloaded.verified_at
      refute reloaded.grace_deadline_at
    end

    test "an unreachable provider still leaves the rotation", ctx do
      serve_status(500)

      assert :unreachable = Verification.recheck(ctx.account)

      # The sweeper runs hourly but the interval is a week, so a row that keeps
      # its old clock is re-fetched every single hour, forever, against a third
      # party that is telling us it has nothing to say. Stamping the scheduler's
      # clock is not a claim that we verified anything (the mark and the grace
      # window are deliberately untouched above) — it only puts the account back
      # into the normal rotation.
      due = Verification.accounts_due_for_recheck() |> Enum.map(& &1.id)
      refute ctx.account.id in due
    end
  end

  describe "accounts_due_for_recheck/1" do
    setup do
      enable()
      :ok
    end

    test "picks up verified accounts whose last check is old enough" do
      user = insert_activated_user()

      fresh =
        user
        |> bluesky_account("fresh#{System.unique_integer([:positive])}.bsky.social")
        |> SocialMediaAccount.verification_changeset(%{
          verified_at: NaiveDateTime.utc_now(),
          last_checked_at: NaiveDateTime.utc_now()
        })
        |> Repo.update!()

      stale =
        user
        |> bluesky_account("stale#{System.unique_integer([:positive])}.bsky.social")
        |> SocialMediaAccount.verification_changeset(%{
          verified_at: ~N[2026-01-01 10:00:00],
          last_checked_at: ~N[2026-01-01 10:00:00]
        })
        |> Repo.update!()

      unverified = bluesky_account(user, "plain#{System.unique_integer([:positive])}.bsky.social")

      due = Verification.accounts_due_for_recheck() |> Enum.map(& &1.id)

      assert stale.id in due
      refute fresh.id in due
      refute unverified.id in due
    end
  end
end
