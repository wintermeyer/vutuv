defmodule Vutuv.MastodonApi.WebPush do
  @moduledoc """
  Web Push delivery: VAPID (RFC 8292) plus `aes128gcm` payload encryption
  (RFC 8291 over RFC 8188).

  **Deliberately no dependency.** The obvious hex package,
  `web_push_encryption`, requires `httpoison ~> 1.0` — the HTTP client this
  project bans (see CLAUDE.md) — and has not shipped since 2021, so taking it
  would pin an ancient second HTTP stack beside `Req` to get a few hundred
  lines of standard crypto. Everything below is in OTP's `:crypto`: ECDH on
  `prime256v1`, HKDF built from `:crypto.mac/4`, and AES-128-GCM. Delivery goes
  through `Req` like every other outbound call.

  A push carries **no content**. The payload names the notification's kind and
  its id and nothing else, so a push service — and anything reading the phone's
  lock screen — learns that something happened, never what was said. The client
  fetches the notification itself over the authenticated API.

  Push is off unless the installation configures a VAPID key pair, which is
  what keeps an intranet installation from trying to reach a push service it
  cannot see (`docs/ADMINS.md`).
  """

  @curve :prime256v1
  @jwt_ttl_seconds 12 * 3600

  @doc "Whether this installation can send pushes at all."
  def configured?, do: is_binary(public_key()) and is_binary(private_key())

  @doc "The VAPID public key a client needs to create a subscription."
  def public_key, do: config(:vapid_public_key)

  defp private_key, do: config(:vapid_private_key)
  defp subject, do: config(:vapid_subject) || "mailto:admin@example.com"

  defp config(key) do
    case Application.get_env(:vutuv, :web_push, [])[key] do
      value when is_binary(value) and value != "" -> value
      _absent -> nil
    end
  end

  @doc """
  Sends one push. Answers `:ok`, or `{:error, :gone}` when the subscription is
  dead — the caller deletes it on that, which is how a push list stays clean
  without a sweeper.
  """
  def send(%{endpoint: endpoint, p256dh: p256dh, auth: auth}, payload) do
    if configured?() do
      deliver(endpoint, p256dh, auth, Jason.encode!(payload))
    else
      {:error, :not_configured}
    end
  end

  defp deliver(endpoint, p256dh, auth, body) do
    with {:ok, ua_public} <- decode(p256dh),
         {:ok, auth_secret} <- decode(auth) do
      {encrypted, _} = encrypt(body, ua_public, auth_secret)

      endpoint
      |> Req.post(
        body: encrypted,
        headers: [
          {"content-encoding", "aes128gcm"},
          {"content-type", "application/octet-stream"},
          {"ttl", "2419200"},
          {"urgency", "normal"},
          {"authorization", authorization(endpoint)}
        ],
        receive_timeout: 10_000,
        retry: false
      )
      |> case do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        {:ok, %{status: status}} when status in [404, 410] -> {:error, :gone}
        {:ok, %{status: status}} -> {:error, {:status, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # RFC 8291 §3.4. The whole point of the ceremony is that the key is derived
  # from a shared secret plus the subscription's own `auth` secret, so a push
  # service that relays the body cannot read it.
  defp encrypt(plaintext, ua_public, auth_secret) do
    salt = :crypto.strong_rand_bytes(16)
    {as_public, as_private} = :crypto.generate_key(:ecdh, @curve)
    shared = :crypto.compute_key(:ecdh, ua_public, as_private, @curve)

    key_info = "WebPush: info" <> <<0>> <> ua_public <> as_public
    ikm = hkdf(auth_secret, shared, key_info, 32)
    cek = hkdf(salt, ikm, "Content-Encoding: aes128gcm" <> <<0>>, 16)
    nonce = hkdf(salt, ikm, "Content-Encoding: nonce" <> <<0>>, 12)

    # The record delimiter is 0x02 for the last (here: only) record.
    padded = plaintext <> <<2>>

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, padded, <<>>, true)

    header = salt <> <<4096::unsigned-big-32, byte_size(as_public)::unsigned-8>> <> as_public
    {header <> ciphertext <> tag, salt}
  end

  # HKDF (RFC 5869) with the one-block expand every Web Push step needs.
  defp hkdf(salt, ikm, info, length) do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    <<key::binary-size(^length), _rest::binary>> = :crypto.mac(:hmac, :sha256, prk, info <> <<1>>)
    key
  end

  # RFC 8292: a JWT the push service checks against the public key we hand it,
  # so only this installation can push to its own subscriptions.
  defp authorization(endpoint) do
    %URI{scheme: scheme, host: host} = URI.parse(endpoint)
    audience = "#{scheme}://#{host}"

    header = encode(Jason.encode!(%{typ: "JWT", alg: "ES256"}))

    claims =
      encode(
        Jason.encode!(%{
          aud: audience,
          exp: System.system_time(:second) + @jwt_ttl_seconds,
          sub: subject()
        })
      )

    signing_input = header <> "." <> claims
    signature = encode(sign(signing_input))

    "vapid t=#{signing_input}.#{signature}, k=#{public_key()}"
  end

  defp sign(message) do
    {:ok, private} = decode(private_key())

    :ecdsa
    |> :crypto.sign(:sha256, message, [private, @curve])
    |> der_to_raw()
  end

  # `:crypto.sign/4` answers DER; JWS wants the bare r‖s pair, each left-padded
  # to the curve's 32 bytes.
  defp der_to_raw(<<0x30, _len, 0x02, r_len, rest::binary>>) do
    # Two matches, not one: `r_len` comes from the clause head and has to be
    # pinned, while `s_len` is bound inside its own pattern and must not be.
    <<r::binary-size(^r_len), tail::binary>> = rest
    <<0x02, s_len, s::binary-size(s_len)>> = tail
    pad(r) <> pad(s)
  end

  defp pad(<<0, rest::binary>>) when byte_size(rest) >= 32, do: pad(rest)
  defp pad(value) when byte_size(value) == 32, do: value
  defp pad(value), do: String.duplicate(<<0>>, 32 - byte_size(value)) <> value

  defp encode(value), do: Base.url_encode64(value, padding: false)

  defp decode(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> Base.decode64(value, padding: false)
    end
  end

  defp decode(_value), do: :error

  @doc """
  A fresh VAPID key pair as the two base64url strings an operator puts in the
  environment. Run it once with `mix run -e`, keep the private key secret.
  """
  def generate_keys do
    {public, private} = :crypto.generate_key(:ecdh, @curve)
    %{public_key: encode(public), private_key: encode(private)}
  end
end
