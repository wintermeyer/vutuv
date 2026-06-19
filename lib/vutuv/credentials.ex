defmodule Vutuv.Credentials do
  @moduledoc """
  Passkey / WebAuthn (FIDO2) credentials — the server side of the passkey login
  added in issue #795.

  A passkey is an *alternative first factor*: a returning member can sign in by
  approving Touch ID / Windows Hello / a security key instead of waiting for an
  emailed PIN. It funnels into the **same** `Vutuv.Accounts.login/2` exit the PIN
  flow uses, so the `Vutuv.Sessions` row, the new-device security email, the
  session-id rotation and the live-socket wiring all happen identically.

  The email-PIN flow is untouched and stays the only way to bootstrap an account:
  enrolment lives behind the logged-in settings page, reachable only by a member
  who already proved they own their email by typing a PIN at least once. A
  passkey is therefore always a faster *return* login, never the root of trust.

  This module is the thin wrapper around `Wax`:

    * it builds the relying-party config (`rp_id/0`, `origins/0`) from the
      endpoint URL, so dev signs `localhost` and prod signs `vutuv.de`,
    * `registration_options/1` / `authentication_options/0` mint a `Wax.Challenge`
      (stored in the session by the controller) **and** the JSON option map the
      browser's `navigator.credentials.create|get` call needs,
    * `register/4` and `verify_authentication/2` verify the authenticator's
      response against the stored challenge and persist / look up the credential.

  Mirrors `Vutuv.Sessions` (the per-device session rows) in shape.
  """

  import Ecto.Query

  require Logger

  alias Vutuv.Accounts.User
  alias Vutuv.Credentials.UserCredential
  alias Vutuv.Repo

  # The COSE algorithms we accept, most-preferred first: ES256 (-7, the passkey
  # default) and RS256 (-257, for the rare authenticator that only does RSA).
  @pub_key_cred_params [-7, -257]

  # How long (seconds) the member has to complete the browser ceremony before the
  # stored challenge expires. Generous enough for a biometric prompt.
  @timeout_seconds 120

  # ── Relying-party config ──

  @doc """
  The WebAuthn Relying Party id: the registrable domain a credential is bound to,
  derived from the endpoint URL (dev `localhost`, prod `vutuv.de`). A credential
  bound to `vutuv.de` works on both the apex and `www.vutuv.de`.
  """
  def rp_id, do: URI.parse(VutuvWeb.Endpoint.url()).host

  @doc """
  The list of page origins an assertion may come from. The endpoint's own origin
  plus, for a real domain, its `www.` sibling (harmless on `localhost`, which a
  browser never reaches with a `www.` prefix).
  """
  def origins do
    uri = URI.parse(VutuvWeb.Endpoint.url())

    uri.host
    |> host_variants()
    |> Enum.map(&URI.to_string(%{uri | host: &1}))
    |> Enum.uniq()
  end

  defp host_variants("www." <> rest = host), do: [host, rest]

  defp host_variants(host),
    do: if(String.contains?(host, "."), do: [host, "www." <> host], else: [host])

  # ── Registration (enrolment) ──

  @doc """
  Mints a registration challenge for `user` and the matching browser
  `navigator.credentials.create` option map.

  Returns `{challenge, options}`: store `challenge` in the session, send
  `options` to the browser as JSON. `options` already base64url-encodes every
  binary (challenge bytes, user handle, excluded credential ids) so it is
  JSON- and WebAuthn-ready. Existing credentials are excluded so the member
  cannot enrol the same authenticator twice.
  """
  def registration_options(%User{} = user) do
    challenge =
      Wax.new_registration_challenge(origin: origins(), rp_id: rp_id(), timeout: @timeout_seconds)

    options = %{
      challenge: b64(challenge.bytes),
      rp: %{id: rp_id(), name: "vutuv"},
      user: %{
        id: b64(user.id),
        name: user.username,
        displayName: display_name(user)
      },
      pubKeyCredParams: Enum.map(@pub_key_cred_params, &%{type: "public-key", alg: &1}),
      excludeCredentials: Enum.map(credential_ids(user), &descriptor/1),
      authenticatorSelection: %{residentKey: "required", userVerification: "preferred"},
      attestation: "none",
      timeout: @timeout_seconds * 1000
    }

    {challenge, options}
  end

  @doc """
  Verifies a registration response (`attestationObject` + `clientDataJSON`,
  both base64url) against the stored `challenge` and, on success, persists the
  new credential for `user` under `nickname`.

  Returns `{:ok, %UserCredential{}}`, or `{:error, reason}` when the attestation
  fails to verify, the payload is malformed, or the credential id is already
  enrolled (the unique constraint).
  """
  def register(%User{} = user, %Wax.Challenge{} = challenge, params, nickname) do
    with {:ok, attestation_object} <- decode(params["attestationObject"]),
         {:ok, client_data_json} <- decode(params["clientDataJSON"]),
         {:ok, {auth_data, _result}} <-
           safe_register(attestation_object, client_data_json, challenge) do
      store_credential(user, auth_data, nickname)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_attestation}
    end
  end

  # Wax.register/3 returns {:error, _} for most bad input but can still raise on
  # some malformed-yet-base64-valid payloads (e.g. client data that is valid JSON
  # but not a valid clientDataJSON object). A hostile client must get a clean
  # error, never a 500, so the raise is caught here.
  defp safe_register(attestation_object, client_data_json, challenge) do
    Wax.register(attestation_object, client_data_json, challenge)
  rescue
    _ -> {:error, :invalid_attestation}
  end

  defp store_credential(user, auth_data, nickname) do
    acd = auth_data.attested_credential_data

    %UserCredential{user_id: user.id}
    |> UserCredential.changeset(%{nickname: nickname})
    |> Ecto.Changeset.put_change(:credential_id, acd.credential_id)
    |> Ecto.Changeset.put_change(:public_key, :erlang.term_to_binary(acd.credential_public_key))
    |> Ecto.Changeset.put_change(:sign_count, auth_data.sign_count || 0)
    |> Ecto.Changeset.put_change(:aaguid, acd.aaguid)
    |> Ecto.Changeset.unique_constraint(:credential_id)
    |> Repo.insert()
  end

  # ── Authentication (login) ──

  @doc """
  Mints an authentication challenge and the matching browser
  `navigator.credentials.get` option map. No allow-list is sent, so the browser
  surfaces any discoverable passkey for this site (usernameless / passkey-first
  login). Returns `{challenge, options}` like `registration_options/1`.
  """
  def authentication_options do
    challenge =
      Wax.new_authentication_challenge(
        origin: origins(),
        rp_id: rp_id(),
        timeout: @timeout_seconds
      )

    options = %{
      challenge: b64(challenge.bytes),
      rpId: rp_id(),
      userVerification: "preferred",
      timeout: @timeout_seconds * 1000
    }

    {challenge, options}
  end

  @doc """
  Verifies an authentication assertion (`rawId`, `authenticatorData`, `signature`,
  `clientDataJSON`, all base64url) against the stored `challenge`.

  Looks the stored credential up by its id, verifies the signature with `Wax`,
  rejects a regressed signature counter (a possible cloned authenticator), bumps
  the counter and `last_used_at`, and returns `{:ok, user}` with the owner
  preloaded. Returns `{:error, reason}` on any failure — deliberately the same
  shape for an unknown credential and a bad signature, so it leaks nothing.
  """
  def verify_authentication(%Wax.Challenge{} = challenge, params) do
    with {:ok, credential_id} <- decode(params["rawId"]),
         {:ok, auth_data_bin} <- decode(params["authenticatorData"]),
         {:ok, sig} <- decode(params["signature"]),
         {:ok, client_data_json} <- decode(params["clientDataJSON"]),
         %UserCredential{} = credential <- get_by_credential_id(credential_id),
         cose_key = :erlang.binary_to_term(credential.public_key, [:safe]),
         {:ok, auth_data} <-
           safe_authenticate(
             credential_id,
             auth_data_bin,
             sig,
             client_data_json,
             challenge,
             cose_key
           ),
         :ok <- check_sign_count(credential, auth_data.sign_count) do
      mark_used(credential, auth_data.sign_count)
      {:ok, Repo.preload(credential, :user).user}
    else
      {:error, _} = error -> error
      nil -> {:error, :unknown_credential}
      _ -> {:error, :invalid_assertion}
    end
  end

  # Clone detection (WebAuthn §7.2 step 17): if the authenticator keeps a counter
  # (either value nonzero), each assertion must report a strictly higher count
  # than the last we saw. An equal-or-lower count means the credential may have
  # been cloned, so the login is refused. Authenticators that never count (both
  # zero) are exempt.
  defp check_sign_count(%UserCredential{id: id, sign_count: stored}, new_count) do
    cond do
      stored == 0 and (new_count == 0 or is_nil(new_count)) ->
        :ok

      is_integer(new_count) and new_count > stored ->
        :ok

      true ->
        Logger.warning(
          "passkey #{id}: signature counter regressed (#{inspect(new_count)} <= #{stored}); " <>
            "refusing login (possible cloned authenticator)"
        )

        {:error, :sign_count_regression}
    end
  end

  defp mark_used(%UserCredential{} = credential, new_count) do
    credential
    |> Ecto.Changeset.change(
      sign_count: max(new_count || 0, credential.sign_count),
      last_used_at: DateTime.utc_now(:second)
    )
    |> Repo.update!()
  end

  # As with safe_register/3: Wax.authenticate/6 can raise on malformed input, so
  # the raise is caught and turned into a clean error.
  defp safe_authenticate(credential_id, auth_data_bin, sig, client_data_json, challenge, cose_key) do
    Wax.authenticate(
      credential_id,
      auth_data_bin,
      sig,
      client_data_json,
      challenge,
      [{credential_id, cose_key}]
    )
  rescue
    _ -> {:error, :invalid_assertion}
  end

  defp get_by_credential_id(credential_id) do
    Repo.one(from(c in UserCredential, where: c.credential_id == ^credential_id))
  end

  # ── The owner's passkey list ──

  @doc "The user's passkeys, most-recently-enrolled first."
  def list_for_user(%User{} = user) do
    Repo.all(
      from(c in UserCredential, where: c.user_id == ^user.id, order_by: [desc: c.inserted_at])
    )
  end

  @doc "Fetches one of the user's own passkeys, or nil (also on a malformed id)."
  def get_for_user(%User{} = user, id) do
    case Vutuv.UUIDv7.cast_or_nil(id) do
      nil -> nil
      uuid -> Repo.get_by(UserCredential, id: uuid, user_id: user.id)
    end
  end

  @doc "Removes one passkey. Removing the last one is allowed — email-PIN remains."
  def delete(%UserCredential{} = credential), do: Repo.delete(credential)

  @doc "How many passkeys the user has enrolled."
  def count_for_user(%User{} = user) do
    Repo.one(from(c in UserCredential, where: c.user_id == ^user.id, select: count(c.id)))
  end

  # ── Helpers ──

  defp credential_ids(%User{} = user) do
    Repo.all(from(c in UserCredential, where: c.user_id == ^user.id, select: c.credential_id))
  end

  defp descriptor(credential_id), do: %{type: "public-key", id: b64(credential_id)}

  # A friendly display name for the authenticator's account picker, from the
  # member's name, falling back to their handle.
  defp display_name(%User{first_name: first, last_name: last, username: slug}) do
    case [first, last] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ") do
      "" -> slug
      name -> name
    end
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  # Decode a base64url field from the browser. Tolerates a missing/padded value
  # rather than raising, so a malformed payload becomes a clean {:error, …}.
  defp decode(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :malformed_payload}
    end
  end

  defp decode(_), do: {:error, :malformed_payload}
end
