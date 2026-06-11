defmodule Vutuv.ApiAuth do
  @moduledoc """
  Credentials for the `/api/v1` JSON API: personal access tokens now, the
  OAuth grant/token machinery in a later phase. See `Vutuv.ApiAuth.Token`
  and `Vutuv.ApiAuth.Scopes`.

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
  alias Vutuv.ApiAuth.{App, Token}
  alias Vutuv.{Moderation, Repo}

  @pat_prefix "vutuv_pat_"

  # last_used_at is an audit trail, not a precise counter; updating it at
  # most once a minute keeps the hot token row from being written on every
  # request.
  @last_used_resolution_seconds 60

  # ── Personal access tokens ──

  @doc """
  Mints a personal access token for `user`. Returns `{:ok, plaintext,
  token}` — the plaintext is shown to the user once and never recoverable.
  """
  def create_pat(%User{} = user, attrs) do
    plaintext = @pat_prefix <> random_token()

    %Token{user_id: user.id, kind: "pat", token_hash: hash_token(plaintext)}
    |> Token.pat_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, token} -> {:ok, plaintext, token}
      {:error, changeset} -> {:error, changeset}
    end
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
    case Vutuv.UUIDv7.cast_or_nil(id) do
      nil -> nil
      uuid -> Repo.get_by(Token, id: uuid, user_id: user.id, kind: "pat")
    end
  end

  # ── Revocation ──

  @doc "Revokes one token. Takes effect on the next API request."
  def revoke_token!(%Token{} = token) do
    token
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second))
    |> Repo.update!()
  end

  @doc """
  Revokes every live credential of the user — PATs and OAuth tokens alike,
  the one-click "log my account out of everything" action. Returns the
  number of tokens revoked.
  """
  def revoke_all_tokens!(%User{} = user) do
    {count, _} =
      Repo.update_all(
        from(t in Token, where: t.user_id == ^user.id and is_nil(t.revoked_at)),
        set: [revoked_at: DateTime.utc_now(:second)]
      )

    count
  end

  # ── Verification (the API pipeline's entry point) ──

  @doc """
  Verifies a bearer token. Returns `{:ok, token, user}` or `{:error,
  :invalid_token | :revoked | :expired | :app_suspended | :account_inactive}`.
  """
  def verify_token(plaintext) when is_binary(plaintext) do
    with {:ok, token} <- lookup(hash_token(plaintext)),
         :ok <- check_live(token),
         :ok <- check_app(token),
         {:ok, user} <- usable_user(token) do
      {:ok, touch_last_used(token), user}
    end
  end

  def verify_token(_other), do: {:error, :invalid_token}

  @doc false
  # Public for tests and the (later) OAuth token minting; not an API for
  # callers outside this context.
  def hash_token(plaintext) do
    :sha256 |> :crypto.hash(plaintext) |> Base.encode16(case: :lower)
  end

  # ── Internals ──

  defp random_token do
    # Base32 keeps the token strictly alphanumeric (double-click selectable);
    # 32 random bytes -> 52 characters, ~165 bits of entropy.
    32 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false)
  end

  defp lookup(hash) do
    case Repo.get_by(Token, token_hash: hash) do
      nil -> {:error, :invalid_token}
      token -> {:ok, token}
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
  defp check_app(%Token{app_id: nil}), do: :ok

  defp check_app(%Token{app_id: app_id}) do
    case Repo.get(App, app_id) do
      %App{suspended_at: nil} -> :ok
      _suspended_or_gone -> {:error, :app_suspended}
    end
  end

  # The same gate the session login applies: unactivated, suspended and
  # deactivated accounts cannot act over the API either.
  defp usable_user(%Token{user_id: user_id}) do
    user = Repo.get(User, user_id)

    cond do
      is_nil(user) -> {:error, :invalid_token}
      not user.activated? -> {:error, :account_inactive}
      Moderation.login_block(user) -> {:error, :account_inactive}
      true -> {:ok, user}
    end
  end

  defp touch_last_used(%Token{} = token) do
    now = DateTime.utc_now(:second)

    if is_nil(token.last_used_at) or
         DateTime.diff(now, token.last_used_at) >= @last_used_resolution_seconds do
      token |> Ecto.Changeset.change(last_used_at: now) |> Repo.update!()
    else
      token
    end
  end
end
