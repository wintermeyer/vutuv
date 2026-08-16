defmodule Vutuv.Profiles.SocialAccountVerification do
  @moduledoc """
  "This social-media account is really mine" verification for the handles a
  member lists on their profile — the social twin of
  `Vutuv.Profiles.LinkVerification`, earning the same small emerald mark.

  Today exactly one network is verifiable:

    * `bluesky_bio` — the member's Bluesky profile description (their bio)
      carries their vutuv profile URL. Bluesky has no `rel="me"`, so the bio is
      the one field only the account holder can write; the threat model is the
      same as the `rel_me` proof on a webpage.

  The state lives on the `social_media_accounts` row and is written **only**
  through `SocialMediaAccount.verification_changeset/2`, never from a form —
  a member who could post `verified_at` would be granting themselves the mark.
  Editing the handle clears it (a different handle is a different account, and
  the proof was read from the old one).

  Verified accounts are re-checked weekly with a grace window before the mark
  drops, mirroring the link and organization-domain re-checks. Crucially, a
  network error is **not** a lost proof: an unreachable AppView leaves the mark
  and the window untouched, because it tells us nothing about the bio.

  Gated by `:verify_social_accounts` (default on). Off = disabled on this
  installation (no outbound calls); intranet-safe.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Bluesky
  alias Vutuv.Profiles.LinkVerification
  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.Repo
  alias Vutuv.WebVerification

  @method "bluesky_bio"

  # The re-check interval and the grace window come from `Vutuv.WebVerification`,
  # shared with the link and organization-domain re-checks.

  @doc "Whether social-account verification is enabled for this installation."
  def enabled?, do: Application.get_env(:vutuv, :verify_social_accounts, true)

  @doc """
  Whether this provider can be proved at all. Only Bluesky today; every other
  listed account (LinkedIn, a code forge, …) simply offers no verify affordance.
  """
  def verifiable?(%SocialMediaAccount{provider: provider}), do: verifiable?(provider)
  def verifiable?(provider), do: provider == "Bluesky"

  @doc """
  The URL the member must put in their Bluesky bio: their canonical vutuv
  profile address. Derived from the endpoint (installability-safe — never a
  literal vutuv.de), shared with the webpage rel=me proof.
  """
  def expected_url(%User{} = user), do: user |> LinkVerification.profile_urls() |> hd()

  @doc """
  Verifies that `account` belongs to `user`. On success stamps the method and
  timestamps and returns `{:ok, account}`.

  Errors: `:disabled` (off on this installation), `:unsupported` (a provider
  with no proof), `:not_found` (the bio does not carry the URL, or the account
  does not exist), `:unreachable` (the network could not be asked — try again,
  this is not a verdict).
  """
  def verify(%SocialMediaAccount{} = account, %User{} = user) do
    cond do
      not enabled?() -> {:error, :disabled}
      not verifiable?(account) -> {:error, :unsupported}
      true -> check_and_stamp(account, user)
    end
  end

  defp check_and_stamp(account, user) do
    case proof_present?(account, user) do
      {:ok, true} -> mark_verified(account)
      {:ok, false} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # `{:ok, boolean}` when the network answered, `{:error, reason}` when it did
  # not. Keeping "no proof" and "could not ask" apart is the whole point: the
  # re-check must not punish an account for our own failed request.
  defp proof_present?(%SocialMediaAccount{provider: "Bluesky", value: handle}, %User{} = user) do
    case Bluesky.fetch_profile(handle) do
      {:ok, %{description: description}} -> {:ok, mentions_profile?(description, user)}
      # A 400 from the AppView means no such actor — a real answer, not a blip.
      {:error, :gone} -> {:ok, false}
      {:error, _transient} -> {:error, :unreachable}
    end
  end

  defp proof_present?(_account, _user), do: {:error, :unsupported}

  # The URL must appear as a whole address, not as the prefix of a longer one:
  # a bio linking to /alicexyz must never verify the member "alice". Handles are
  # [a-z0-9_] (Vutuv.Handles), so the character after the URL may be anything
  # else — a space, a full stop, a bracket, or the end of the bio.
  defp mentions_profile?(description, %User{} = user) when is_binary(description) do
    pattern = Regex.compile!(Regex.escape(expected_url(user)) <> "(?![a-z0-9_])", "i")
    Regex.match?(pattern, description)
  end

  defp mentions_profile?(_description, _user), do: false

  defp mark_verified(%SocialMediaAccount{} = account) do
    now = now()

    account
    |> SocialMediaAccount.verification_changeset(%{
      verification_method: @method,
      verified_at: now,
      last_checked_at: now,
      grace_deadline_at: nil
    })
    |> Repo.update()
  end

  # --- periodic re-check ------------------------------------------------------

  @doc "Verified accounts whose last check is older than the interval."
  def accounts_due_for_recheck(now \\ NaiveDateTime.utc_now()) do
    cutoff = WebVerification.recheck_cutoff(now)

    Repo.all(
      from(a in SocialMediaAccount,
        where:
          not is_nil(a.verified_at) and
            (is_nil(a.last_checked_at) or a.last_checked_at < ^cutoff),
        preload: [:user]
      )
    )
  end

  @doc """
  Re-checks all due verified accounts (called by the sweeper). No-op when
  verification is disabled. Returns the count of accounts that lost their mark
  this run.
  """
  def recheck_due_accounts do
    if enabled?() do
      # Each check is one blocking HTTP call (no DB connection held during it),
      # so run them with bounded concurrency instead of summing every account's
      # network latency serially.
      accounts_due_for_recheck()
      |> Task.async_stream(&recheck/1, max_concurrency: 10, ordered: false, timeout: :infinity)
      |> Enum.count(fn {:ok, outcome} -> outcome == :demoted end)
    else
      0
    end
  end

  @doc """
  Re-checks one verified account. A proof still in place refreshes
  `last_checked_at` and clears any grace window; a vanished one starts the
  window, waits it out, then drops the mark. A network failure leaves the mark
  and the window alone, and only advances the clock.

  Returns `:ok`, `:grace_started`, `:in_grace`, `:demoted` or `:unreachable`.
  """
  def recheck(%SocialMediaAccount{user: %User{} = user} = account) do
    now = now()

    case proof_present?(account, user) do
      {:ok, true} ->
        account
        |> SocialMediaAccount.verification_changeset(%{
          last_checked_at: now,
          grace_deadline_at: nil
        })
        |> Repo.update()

        :ok

      {:ok, false} ->
        handle_recheck_failure(account, now)

      # We learned nothing about the bio, so we hold the mark and the grace
      # window — an AppView outage must not un-verify the whole network. The
      # clock is still stamped: it is the scheduler's, not a claim that anything
      # was verified, and without it the row stays due on every hourly sweep
      # while the interval is a week, so one erroring provider is re-fetched
      # 168x more often than intended, forever. Nothing degrades meanwhile —
      # the mark keeps standing until a check actually reads the bio.
      {:error, _reason} ->
        account
        |> SocialMediaAccount.verification_changeset(%{last_checked_at: now})
        |> Repo.update()

        :unreachable
    end
  end

  defp handle_recheck_failure(%SocialMediaAccount{} = account, now) do
    case WebVerification.grace_step(account.grace_deadline_at, now) do
      {:grace_started, deadline} ->
        account
        |> SocialMediaAccount.verification_changeset(%{
          last_checked_at: now,
          grace_deadline_at: deadline
        })
        |> Repo.update()

        :grace_started

      :in_grace ->
        account
        |> SocialMediaAccount.verification_changeset(%{last_checked_at: now})
        |> Repo.update()

        :in_grace

      :demote ->
        account
        |> SocialMediaAccount.verification_changeset(%{
          verification_method: nil,
          verified_at: nil,
          last_checked_at: now,
          grace_deadline_at: nil
        })
        |> Repo.update()

        :demoted
    end
  end

  defp now, do: NaiveDateTime.utc_now(:second)
end
