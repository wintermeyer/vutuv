defmodule Vutuv.ApiAuth.OAuth do
  @moduledoc """
  The OAuth 2 authorization-code flow (RFC 6749 + PKCE per RFC 7636,
  hardened per RFC 9700): `validate_authorize/1` checks an incoming
  authorize request, `approve/2` records the user's consent and mints the
  one-time code, `exchange/1` and `refresh/1` are the token endpoint's two
  grant types, `revoke/1` is RFC 7009.

  Deliberate choices:

    * **PKCE (S256) is mandatory for every native (`protocol: "vutuv"`)
      client**, and the client secret is required at the token endpoint —
      2.0 supports confidential clients only (a browser-only app needs a
      small server-side exchange).
    * **A `protocol: "mastodon"` app may omit PKCE**: the phone clients this
      adapter exists for frequently send no challenge, and refusing them
      would defeat the compatibility. Such a code stores the
      `@mastodon_no_pkce` sentinel and `check_code_params/2` skips the
      verifier check. The client secret is still required, so this is not an
      unauthenticated exchange — and the sentinel cannot be smuggled in from
      outside, because `check_pkce/1` accepts a challenge of 43..128 bytes
      only and the sentinel is 16. Do not "tidy" that length check away.
    * Authorization codes are one-time and 10-minute; **redeeming a code
      twice revokes every token of its grant** (the RFC's theft signal).
    * Refresh tokens **rotate on every use**; using a rotated (revoked)
      refresh token again also revokes the whole grant's tokens.
    * **A Mastodon grant gets no refresh token and its access token carries
      no `expires_at`**, the way upstream Mastodon issues them — so nothing
      rotates and nothing ages out, and such a session ends only on explicit
      revocation, app suspension, or the account falling inactive. What
      bounds that instead is `VutuvWeb.Plug.MastodonApiAuth`, which
      re-derives the identity's powers from **live** roles on every request:
      withdrawing a role or clearing `mastodon_clients?` takes effect at
      once rather than at some next refresh that never comes.
    * All secrets are stored as SHA-256 hashes, like everything else in
      `Vutuv.ApiAuth`.
  """

  import Ecto.Query

  alias Vutuv.ApiAuth
  alias Vutuv.ApiAuth.{App, AuthCode, Grant, Scopes, Token}
  alias Vutuv.MastodonApi.Access
  alias Vutuv.MastodonApi.Scopes, as: MastodonScopes
  alias Vutuv.Repo

  @code_prefix "vutuv_ac_"
  @access_prefix "vutuv_at_"
  @refresh_prefix "vutuv_rt_"

  @code_ttl_seconds 600
  @access_ttl_seconds 7_200
  @refresh_ttl_days 90
  @mastodon_no_pkce "mastodon-no-pkce"

  def access_ttl_seconds, do: @access_ttl_seconds

  # ── The authorize request (GET /oauth/authorize) ──

  @doc """
  Validates an incoming authorize request. `{:ok, request}` with the app,
  parsed scopes, exact redirect URI, state and PKCE challenge — or
  `{:error, reason}`. Anything wrong with client_id/redirect_uri must NOT
  redirect (we'd be an open redirector); scope/PKCE problems may.
  """
  def validate_authorize(params) do
    with {:ok, app} <- fetch_client(params["client_id"]),
         {:ok, redirect_uri} <- check_redirect_uri(app, params["redirect_uri"]),
         :ok <- check_response_type(params["response_type"]),
         {:ok, scopes} <- parse_scopes(app, params["scope"]),
         {:ok, challenge} <- check_pkce(app, params) do
      {:ok,
       %{
         app: app,
         scopes: scopes,
         redirect_uri: redirect_uri,
         state: params["state"],
         code_challenge: challenge
       }}
    end
  end

  defp fetch_client(client_id) do
    case ApiAuth.get_app_by_client_id(client_id) do
      nil -> {:error, :unknown_client}
      %App{suspended_at: %DateTime{}} -> {:error, :app_suspended}
      %App{} = app -> {:ok, app}
    end
  end

  defp check_redirect_uri(app, redirect_uri) do
    if is_binary(redirect_uri) and redirect_uri in app.redirect_uris do
      {:ok, redirect_uri}
    else
      {:error, :invalid_redirect_uri}
    end
  end

  defp check_response_type("code"), do: :ok
  defp check_response_type(_other), do: {:error, :unsupported_response_type}

  defp parse_scopes(scope) when is_binary(scope) do
    scopes = scope |> String.split(" ", trim: true) |> Enum.uniq()

    if scopes != [] and Enum.all?(scopes, &Scopes.valid?/1) do
      {:ok, scopes}
    else
      {:error, :invalid_scope}
    end
  end

  defp parse_scopes(_missing), do: {:error, :invalid_scope}

  defp parse_scopes(%App{protocol: "mastodon", registered_scopes: registered}, scope),
    do: MastodonScopes.authorize(scope, registered)

  defp parse_scopes(%App{}, scope), do: parse_scopes(scope)

  defp check_pkce(%App{protocol: "mastodon"}, params) do
    if is_binary(params["code_challenge"]), do: check_pkce(params), else: {:ok, @mastodon_no_pkce}
  end

  defp check_pkce(%App{}, params), do: check_pkce(params)

  defp check_pkce(%{"code_challenge" => challenge} = params) do
    cond do
      params["code_challenge_method"] != "S256" -> {:error, :invalid_pkce}
      not is_binary(challenge) -> {:error, :invalid_pkce}
      byte_size(challenge) not in 43..128 -> {:error, :invalid_pkce}
      true -> {:ok, challenge}
    end
  end

  defp check_pkce(_params), do: {:error, :invalid_pkce}

  # ── Consent (POST /oauth/authorize) ──

  @doc """
  Records the user's consent and mints the one-time code: the grant row is
  created or refreshed (scopes are the union of old and new — consent only
  ever widens, revocation is explicit), the code carries the PKCE
  challenge. Returns the code plaintext for the redirect.
  """
  def approve(user, request, identity \\ nil)

  def approve(user, %{app: %App{protocol: "mastodon"}} = request, identity) do
    with {:ok, organization, scopes} <- Access.select(user, identity, request.scopes) do
      do_approve(user, request, organization, scopes)
    end
  end

  def approve(user, request, _identity), do: do_approve(user, request, nil, request.scopes)

  defp do_approve(user, %{app: app} = request, organization, scopes) do
    code = @code_prefix <> ApiAuth.random_token()

    {:ok, _auth_code} =
      Repo.transaction(fn ->
        grant = upsert_grant!(user, app, scopes)

        Repo.insert!(%AuthCode{
          user_id: user.id,
          app_id: app.id,
          grant_id: grant.id,
          organization_id: organization && organization.id,
          code_hash: ApiAuth.hash_token(code),
          redirect_uri: request.redirect_uri,
          scopes: scopes,
          code_challenge: request.code_challenge,
          expires_at: seconds_from_now(@code_ttl_seconds)
        })
      end)

    {:ok, code}
  end

  defp upsert_grant!(user, app, scopes) do
    case Repo.get_by(Grant, user_id: user.id, app_id: app.id) do
      nil ->
        %Grant{user_id: user.id, app_id: app.id, scopes: scopes}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.unique_constraint(:user_id, name: :oauth_grants_user_id_app_id_index)
        |> Repo.insert()
        |> case do
          {:ok, grant} ->
            grant

          # Lost the first-mint race against a concurrent authorize (the row
          # exists now): fold this consent into the winner's grant instead of
          # raising a raw unique-violation 500. Ecto wraps the insert in a
          # savepoint, so this error doesn't abort approve/2's transaction.
          {:error, _changeset} ->
            Repo.get_by!(Grant, user_id: user.id, app_id: app.id) |> merge_grant!(scopes)
        end

      grant ->
        merge_grant!(grant, scopes)
    end
  end

  # A revoked grant starts fresh: the user explicitly took the old scopes away,
  # so re-authorization grants exactly what this consent screen showed — never
  # the union with the revoked set (that would silently resurrect a scope the
  # user removed and never re-approved). An active grant widens by union.
  defp merge_grant!(%Grant{revoked_at: revoked} = grant, scopes) when not is_nil(revoked) do
    grant |> Ecto.Changeset.change(scopes: scopes, revoked_at: nil) |> Repo.update!()
  end

  defp merge_grant!(%Grant{} = grant, scopes) do
    grant |> Ecto.Changeset.change(scopes: Enum.uniq(grant.scopes ++ scopes)) |> Repo.update!()
  end

  # ── The token endpoint (POST /oauth/token) ──

  @doc """
  `grant_type=authorization_code`: code + PKCE verifier + client
  credentials → an access/refresh pair. Errors use the RFC's vocabulary
  (`:invalid_client` answers 401, the rest 400).
  """
  def exchange(params) do
    with {:ok, app} <- authenticate_client(params),
         {:ok, code} <- fetch_code(app, params["code"]),
         :ok <- consume_code(code),
         :ok <- check_code_params(code, params) do
      mint_pair(code.grant_id, code.user_id, code.organization_id, app, code.scopes)
    end
  end

  @doc "`grant_type=refresh_token`: rotate the pair; reuse revokes the grant's tokens."
  def refresh(params) do
    with {:ok, app} <- authenticate_client(params),
         {:ok, token} <- fetch_refresh(app, params["refresh_token"]) do
      cond do
        # A rotated refresh token coming back is the theft signal.
        token.revoked_at != nil ->
          ApiAuth.revoke_grant_tokens!(token.grant_id)
          {:error, :invalid_grant}

        expired?(token) or grant_revoked?(token.grant_id) ->
          {:error, :invalid_grant}

        true ->
          rotate_refresh(token, app)
      end
    end
  end

  # Atomic rotation: the `is_nil(revoked_at)` guard lets exactly one of two
  # concurrent refreshes win. The loser saw zero rows, so its token was already
  # rotated — treat it as reuse and revoke the grant.
  defp rotate_refresh(token, app) do
    {n, _} =
      Repo.update_all(
        from(t in Token, where: t.id == ^token.id and is_nil(t.revoked_at)),
        set: [revoked_at: DateTime.utc_now(:second)]
      )

    if n == 1 do
      mint_pair(token.grant_id, token.user_id, token.organization_id, app, token.scopes)
    else
      ApiAuth.revoke_grant_tokens!(token.grant_id)
      {:error, :invalid_grant}
    end
  end

  @doc """
  RFC 7009 revocation: kills the presented token (and, for a refresh
  token, the whole pair via the grant). Always `:ok` for valid client
  credentials — unknown tokens are not an error, per spec.
  """
  def revoke(params) do
    with {:ok, app} <- authenticate_client(params) do
      case lookup_app_token(app, params["token"]) do
        %Token{kind: "refresh"} = token -> ApiAuth.revoke_grant_tokens!(token.grant_id)
        %Token{revoked_at: nil} = token -> ApiAuth.revoke_token!(token)
        _unknown_or_revoked -> :noop
      end

      :ok
    end
  end

  # ── Internals ──

  defp authenticate_client(params) do
    with {:ok, app} <- fetch_client(params["client_id"]),
         secret when is_binary(secret) <- params["client_secret"],
         true <-
           Plug.Crypto.secure_compare(ApiAuth.hash_token(secret), app.client_secret_hash) do
      {:ok, app}
    else
      {:error, :app_suspended} -> {:error, :app_suspended}
      _bad_credentials -> {:error, :invalid_client}
    end
  end

  defp fetch_code(app, code) when is_binary(code) do
    case Repo.get_by(AuthCode, code_hash: ApiAuth.hash_token(code), app_id: app.id) do
      nil -> {:error, :invalid_grant}
      %AuthCode{} = auth_code -> {:ok, auth_code}
    end
  end

  defp fetch_code(_app, _missing), do: {:error, :invalid_grant}

  # One-time use: a second redemption revokes everything the grant minted.
  defp consume_code(%AuthCode{used_at: %DateTime{}} = code) do
    ApiAuth.revoke_grant_tokens!(code.grant_id)
    {:error, :invalid_grant}
  end

  defp consume_code(%AuthCode{} = code) do
    # Atomic one-time consumption: the `is_nil(used_at)` guard makes exactly one
    # of two concurrent exchanges win. The loser matched zero rows, so it is a
    # second redemption — fire the theft signal like the used_at branch above.
    {count, _} =
      Repo.update_all(
        from(c in AuthCode, where: c.id == ^code.id and is_nil(c.used_at)),
        set: [used_at: DateTime.utc_now(:second)]
      )

    if count == 1 do
      :ok
    else
      ApiAuth.revoke_grant_tokens!(code.grant_id)
      {:error, :invalid_grant}
    end
  end

  defp check_code_params(code, params) do
    cond do
      DateTime.compare(code.expires_at, DateTime.utc_now()) != :gt -> {:error, :invalid_grant}
      params["redirect_uri"] != code.redirect_uri -> {:error, :invalid_grant}
      code.code_challenge == @mastodon_no_pkce -> :ok
      not pkce_verifies?(code.code_challenge, params["code_verifier"]) -> {:error, :invalid_grant}
      true -> :ok
    end
  end

  defp pkce_verifies?(challenge, verifier) when is_binary(verifier) do
    derived = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
    Plug.Crypto.secure_compare(derived, challenge)
  end

  defp pkce_verifies?(_challenge, _missing), do: false

  defp fetch_refresh(app, value) when is_binary(value) do
    case lookup_app_token(app, value) do
      %Token{kind: "refresh"} = token -> {:ok, token}
      _other -> {:error, :invalid_grant}
    end
  end

  defp fetch_refresh(_app, _missing), do: {:error, :invalid_grant}

  defp expired?(%Token{expires_at: %DateTime{} = at}),
    do: DateTime.compare(at, DateTime.utc_now()) != :gt

  defp expired?(_token), do: false

  defp grant_revoked?(grant_id) do
    not Repo.exists?(from(g in Grant, where: g.id == ^grant_id and is_nil(g.revoked_at)))
  end

  defp mint_pair(grant_id, user_id, organization_id, %App{protocol: "mastodon"} = app, scopes) do
    access = @access_prefix <> ApiAuth.random_token()
    insert_token!(grant_id, user_id, organization_id, app.id, scopes, "access", access, nil)

    {:ok,
     %{
       access_token: access,
       token_type: "Bearer",
       scope: Enum.join(scopes, " "),
       created_at: System.system_time(:second)
     }}
  end

  defp mint_pair(grant_id, user_id, organization_id, %App{} = app, scopes) do
    access = @access_prefix <> ApiAuth.random_token()
    refresh = @refresh_prefix <> ApiAuth.random_token()

    {:ok, _} =
      Repo.transaction(fn ->
        insert_token!(
          grant_id,
          user_id,
          organization_id,
          app.id,
          scopes,
          "access",
          access,
          @access_ttl_seconds
        )

        insert_token!(
          grant_id,
          user_id,
          organization_id,
          app.id,
          scopes,
          "refresh",
          refresh,
          @refresh_ttl_days * 86_400
        )
      end)

    {:ok,
     %{
       access_token: access,
       refresh_token: refresh,
       token_type: "Bearer",
       expires_in: @access_ttl_seconds,
       scope: Enum.join(scopes, " ")
     }}
  end

  defp insert_token!(
         grant_id,
         user_id,
         organization_id,
         app_id,
         scopes,
         kind,
         plaintext,
         ttl_seconds
       ) do
    Repo.insert!(%Token{
      user_id: user_id,
      organization_id: organization_id,
      app_id: app_id,
      grant_id: grant_id,
      kind: kind,
      token_hash: ApiAuth.hash_token(plaintext),
      scopes: scopes,
      expires_at: expires_at(ttl_seconds)
    })
  end

  defp expires_at(nil), do: nil
  defp expires_at(seconds), do: seconds_from_now(seconds)

  defp lookup_app_token(app, value) when is_binary(value) do
    Repo.get_by(Token, token_hash: ApiAuth.hash_token(value), app_id: app.id)
  end

  defp lookup_app_token(_app, _missing), do: nil

  defp seconds_from_now(seconds) do
    DateTime.add(DateTime.utc_now(:second), seconds)
  end
end
