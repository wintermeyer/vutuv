defmodule Vutuv.ApiAuth do
  @moduledoc """
  Credentials for the `/api/2.0` JSON API: personal access tokens, the
  registered OAuth apps with their grants, and token verification. See
  `Vutuv.ApiAuth.Token`, `Vutuv.ApiAuth.OAuth` and `Vutuv.ApiAuth.Scopes`.

  Tokens are opaque random strings with a recognizable prefix
  (`vutuv_pat_…` / `vutuv_at_…` / `vutuv_rt_…`, for secret scanners) whose
  SHA-256 hash is the only thing stored — a leaked database dump mints no
  bearer credentials. The plaintext exists once, in the return value of the
  minting function; the UI shows it exactly once.

  Verification is a DB lookup per request, on purpose: revoking a token (or
  suspending an app — the "bad player" kill switch) takes effect on the
  very next request, with no cache to wait out. Suspended / deactivated /
  unactivated accounts fail verification the same way they cannot log in.
  """

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.ApiAuth.{App, AppToken, AuthCode, Grant, Token}
  alias Vutuv.MastodonApi.PushSubscription
  alias Vutuv.{Moderation, Repo}
  alias Vutuv.Organizations.Organization

  @pat_prefix "vutuv_pat_"
  @client_id_prefix "vutuv_app_"
  @secret_prefix "vutuv_sec_"

  # last_used_at is an audit trail, not a precise counter; updating it at
  # most once a minute keeps the hot token row from being written on every
  # request.
  @last_used_resolution_seconds 60

  @doc false
  # The app tokens in `Vutuv.ApiAuth.OAuth` stamp the same column and must not
  # pick their own number for it.
  def last_used_resolution_seconds, do: @last_used_resolution_seconds

  # ── Personal access tokens ──

  @doc """
  Mints a personal access token for `user`. Returns `{:ok, plaintext,
  token}` — the plaintext is shown to the user once and never recoverable.
  """
  def create_pat(%User{} = user, attrs) do
    plaintext = @pat_prefix <> random_token()

    changeset =
      %Token{user_id: user.id, kind: "pat", token_hash: hash_token(plaintext)}
      |> Token.pat_changeset(attrs)

    with {:ok, token} <- Repo.insert(changeset), do: {:ok, plaintext, token}
  end

  @doc "A changeset for the PAT form."
  def change_pat(attrs \\ %{}), do: Token.pat_changeset(%Token{}, attrs)

  @doc "The user's active (not revoked) personal access tokens, newest first."
  def list_pats(%User{} = user) do
    Repo.all(
      from(t in Token,
        where: t.user_id == ^user.id and t.kind == "pat" and is_nil(t.revoked_at),
        order_by: [desc: t.id]
      )
    )
  end

  @doc "Fetches one of the user's own PATs, or nil (also on a malformed id)."
  def get_pat(%User{} = user, id) do
    Vutuv.UUIDv7.with_cast(id, &Repo.get_by(Token, id: &1, user_id: user.id, kind: "pat"))
  end

  # ── Revocation ──

  @doc "Revokes one token. Takes effect on the next API request."
  def revoke_token!(%Token{} = token) do
    token =
      token |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second)) |> Repo.update!()

    drop_push_subscriptions!([token.id])
    token
  end

  @doc """
  Revokes every live credential of the user — PATs and OAuth tokens alike,
  the one-click "log my account out of everything" action. Returns the
  number of tokens revoked.
  """
  def revoke_all_tokens!(%User{} = user) do
    live = from(t in Token, where: t.user_id == ^user.id and is_nil(t.revoked_at))
    drop_push_subscriptions!(from(t in live, select: t.id))

    {count, _} = Repo.update_all(live, set: [revoked_at: DateTime.utc_now(:second)])

    count
  end

  # ── Registered apps (OAuth clients) ──

  @doc """
  Registers a third-party app for `user` (self-service, but always owned
  by a vutuv account — the accountability anchor). Returns `{:ok, app,
  client_secret}`; the secret is shown once and stored only as a hash.
  """
  def create_app(%User{} = user, attrs) do
    secret = @secret_prefix <> random_token()

    changeset =
      %App{
        user_id: user.id,
        client_id: @client_id_prefix <> random_token(16),
        client_secret_hash: hash_token(secret)
      }
      |> App.changeset(attrs)

    with {:ok, app} <- Repo.insert(changeset), do: {:ok, app, secret}
  end

  @doc "Registers an unattended client through Mastodon's public app endpoint."
  def create_mastodon_app(attrs) do
    secret = @secret_prefix <> random_token()

    changeset =
      %App{
        protocol: "mastodon",
        client_id: @client_id_prefix <> random_token(16),
        client_secret_hash: hash_token(secret)
      }
      |> App.mastodon_changeset(attrs)

    with {:ok, app} <- Repo.insert(changeset), do: {:ok, app, secret}
  end

  def change_app(%App{} = app, attrs \\ %{}), do: App.changeset(app, attrs)

  def update_app(%App{} = app, attrs) do
    app |> App.changeset(attrs) |> Repo.update()
  end

  @doc "Mints a fresh client secret (the old one stops working). Returns `{app, secret}`."
  def regenerate_secret!(%App{} = app) do
    secret = @secret_prefix <> random_token()
    app = app |> Ecto.Changeset.change(client_secret_hash: hash_token(secret)) |> Repo.update!()
    {app, secret}
  end

  def list_apps(%User{} = user) do
    Repo.all(from(a in App, where: a.user_id == ^user.id, order_by: [desc: a.id]))
  end

  @doc "One of the user's own apps, or nil (also on a malformed id)."
  def get_app(%User{} = user, id) do
    Vutuv.UUIDv7.with_cast(id, &Repo.get_by(App, id: &1, user_id: user.id))
  end

  def get_app_by_client_id(client_id) when is_binary(client_id) do
    Repo.get_by(App, client_id: client_id)
  end

  def get_app_by_client_id(_other), do: nil

  @doc "Deletes the app; its grants, codes and tokens cascade away with it."
  def delete_app!(%App{} = app), do: Repo.delete!(app)

  # ── Admin: the bad-player kill switch ──

  def list_all_apps do
    Repo.all(from(a in App, order_by: [desc: a.id], preload: :user))
  end

  def get_any_app(id) do
    Vutuv.UUIDv7.with_cast(id, &Repo.get(App, &1))
  end

  @doc "Suspends the app: every one of its tokens fails on its next request."
  def suspend_app!(%App{} = app) do
    app |> Ecto.Changeset.change(suspended_at: DateTime.utc_now(:second)) |> Repo.update!()
  end

  def unsuspend_app!(%App{} = app) do
    app |> Ecto.Changeset.change(suspended_at: nil) |> Repo.update!()
  end

  # ── Grants (the user × app authorizations) ──

  @doc "The user's active app authorizations, app preloaded — the Connected apps page."
  def list_grants(%User{} = user) do
    Repo.all(
      from(g in Grant,
        where: g.user_id == ^user.id and is_nil(g.revoked_at),
        order_by: [desc: g.updated_at],
        preload: :app
      )
    )
  end

  def get_grant(%User{} = user, id) do
    Vutuv.UUIDv7.with_cast(id, fn uuid ->
      Repo.one(from(g in Grant, where: g.id == ^uuid and g.user_id == ^user.id, preload: :app))
    end)
  end

  @doc """
  Revokes the authorization: the grant is marked and every token minted
  under it dies. One click on the Connected apps page.
  """
  def revoke_grant!(%Grant{} = grant) do
    {:ok, grant} =
      Repo.transaction(fn ->
        revoke_grant_tokens!(grant.id)

        grant
        |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second))
        |> Repo.update!()
      end)

    grant
  end

  @doc false
  # Kills every live token of a grant — grant revocation, and the OAuth
  # code-reuse / refresh-reuse theft signals.
  def revoke_grant_tokens!(grant_id) do
    live = from(t in Token, where: t.grant_id == ^grant_id and is_nil(t.revoked_at))
    drop_push_subscriptions!(from(t in live, select: t.id))

    {count, _} = Repo.update_all(live, set: [revoked_at: DateTime.utc_now(:second)])

    count
  end

  # A Web Push subscription is a standing permission to reach a device, and
  # revocation here is a soft `revoked_at` rather than a delete — so the
  # subscription's `ON DELETE CASCADE` never fires and the row outlives the
  # credential that created it. Dropping it is what stops the pushes; the
  # revoked-token join in `Vutuv.MastodonApi.PushDispatcher` is the belt to this
  # braces, since it holds for any revocation path added later that forgets to
  # come here.
  # Deleted **before** the update, while the ids are still selectable by "live
  # tokens of this user"; afterwards there is nothing left to name them by. The
  # two statements are not wrapped in a transaction on purpose: the worst
  # interleaving drops a subscription whose token then survives, which costs a
  # device its pushes until it re-subscribes — the other order would keep a
  # device reachable by a dead credential, and only one of those is a security
  # question.
  defp drop_push_subscriptions!(token_ids) when is_list(token_ids) do
    Repo.delete_all(from(s in PushSubscription, where: s.api_token_id in ^token_ids))
    :ok
  end

  defp drop_push_subscriptions!(%Ecto.Query{} = token_ids) do
    Repo.delete_all(from(s in PushSubscription, where: s.api_token_id in subquery(token_ids)))
    :ok
  end

  # ── Housekeeping ──

  # How long an unattended registration and a spent authorization code are kept.
  # Both are generous on purpose: the point is to bound growth, not to reclaim
  # bytes, and a member who starts setting a client up on Friday should still
  # find it there on Monday.
  @sweep_after_days 7

  @doc """
  Deletes what the OAuth tables accumulate on their own (issue #1557). Returns
  `%{apps: deleted, codes: deleted}`.

  Two things pile up without anybody doing anything wrong. A Mastodon client
  registers itself **before** the consent screen, so every setup somebody starts
  and abandons leaves an ownerless `oauth_apps` row; and every consent mints an
  `oauth_auth_codes` row that is dead ten minutes later whether or not it was
  ever redeemed. Nothing removed either, so both grew forever.

  **What "abandoned" must mean is the whole of this function.** "No grant" alone
  is wrong since v7.317.0: a `client_credentials` app holds a live token and has
  no grant at all, so that test would delete exactly the apps this installation's
  newest feature works for. An app is abandoned only when no member ever
  consented **and** it holds no live token of its own. Native `/developers/apps`
  registrations are never touched — a developer made those by hand.

  A spent code is kept for the same week rather than dropped the moment it
  expires, because the row is what makes a **replay** detectable: `consume_code/1`
  reads `used_at` and revokes the whole grant's tokens when a code comes back
  twice. Delete it too eagerly and that theft signal answers "unknown code".
  """
  def sweep do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -@sweep_after_days * 86_400)

    %{apps: sweep_abandoned_apps(cutoff), codes: sweep_spent_codes(cutoff)}
  end

  # `not exists`, deliberately, where `x not in subquery` reads more naturally.
  # Two reasons, and the second is the one that bites. Postgres cannot turn
  # `NOT IN` into an anti-join — the NULL semantics forbid it — so it plans a
  # hashed SubPlan and silently falls back to re-scanning the subquery **per
  # candidate row** once the planner thinks it no longer fits `work_mem`. That is
  # a cliff, not a slope, and it is driven by an estimate, so a stale ANALYZE can
  # tip it early; an installation large enough to need this sweep is exactly the
  # one where the sweep would then run for hours and log nothing. `not exists`
  # plans a Hash Anti Join at any size. And it removes the NULL trap by
  # construction rather than by an argument about the two columns being NOT NULL,
  # so widening either one later cannot quietly turn this into a no-op that reads
  # as "nothing to clean up".
  defp sweep_abandoned_apps(cutoff) do
    {count, _} =
      Repo.delete_all(
        from(a in App,
          as: :app,
          where: a.protocol == "mastodon",
          where: a.inserted_at < ^cutoff,
          where: not exists(from(g in Grant, where: g.app_id == parent_as(:app).id)),
          where:
            not exists(
              from(t in AppToken,
                where: t.app_id == parent_as(:app).id and is_nil(t.revoked_at)
              )
            )
        )
      )

    count
  end

  defp sweep_spent_codes(cutoff) do
    {count, _} = Repo.delete_all(from(c in AuthCode, where: c.inserted_at < ^cutoff))
    count
  end

  # ── Verification (the API pipeline's entry point) ──

  @doc """
  Verifies a bearer token. Returns `{:ok, token, user}` or `{:error,
  :invalid_token | :revoked | :expired | :app_suspended | :account_inactive}`.
  """
  def verify_token(plaintext) when is_binary(plaintext) do
    with {:ok, token, user, app, organization} <- lookup(hash_token(plaintext)),
         :ok <- check_live(token),
         :ok <- check_app(token, app),
         :ok <- check_user(user) do
      token = %{token | app: app, organization: organization}
      {:ok, touch_last_used(token), user}
    end
  end

  def verify_token(_other), do: {:error, :invalid_token}

  @doc false
  # Public for tests, OAuth (`Vutuv.ApiAuth.OAuth`) and webhooks; the token shape
  # lives in `Vutuv.Token` (shared with the session tokens), this just keeps the
  # `ApiAuth.*` name those callers use. (`Token` is the schema alias here, so the
  # shared module is referenced fully-qualified.)
  def hash_token(plaintext), do: Vutuv.Token.hash_token(plaintext)

  # ── Internals ──

  @doc false
  # Public for OAuth (codes, access/refresh tokens) and webhook secrets; not a
  # caller API. Delegates to the shared `Vutuv.Token`.
  def random_token(bytes \\ 32), do: Vutuv.Token.random_token(bytes)

  # One round trip for the hot path: the token, its user and (for OAuth
  # tokens) its app arrive together; all further checks are in-memory.
  defp lookup(hash) do
    from(t in Token,
      where: t.token_hash == ^hash,
      join: u in User,
      on: u.id == t.user_id,
      left_join: a in App,
      on: a.id == t.app_id,
      left_join: o in Organization,
      on: o.id == t.organization_id,
      select: {t, u, a, o}
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :invalid_token}
      {token, user, app, organization} -> {:ok, token, user, app, organization}
    end
  end

  defp check_live(%Token{revoked_at: %DateTime{}}), do: {:error, :revoked}

  defp check_live(%Token{expires_at: %DateTime{} = expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
      do: :ok,
      else: {:error, :expired}
  end

  defp check_live(_token), do: :ok

  # The "bad player" kill switch: a suspended app's tokens all die at once.
  defp check_app(%Token{app_id: nil}, _app), do: :ok
  defp check_app(%Token{}, %App{suspended_at: nil}), do: :ok
  defp check_app(%Token{}, _suspended_or_gone), do: {:error, :app_suspended}

  # The same gate the session login applies: unactivated, suspended and
  # deactivated accounts cannot act over the API either.
  defp check_user(%User{} = user) do
    cond do
      not user.email_confirmed? -> {:error, :account_inactive}
      Moderation.login_block(user) -> {:error, :account_inactive}
      true -> :ok
    end
  end

  defp touch_last_used(%Token{} = token) do
    Repo.touch_throttled(token, :last_used_at, @last_used_resolution_seconds)
  end
end
