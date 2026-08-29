defmodule Vutuv.WebPush do
  @moduledoc """
  Web Push delivery: VAPID (RFC 8292) plus `aes128gcm` payload encryption
  (RFC 8291 over RFC 8188).

  **Two callers, one implementation.** This started life inside the
  Mastodon-compatible adapter, where a subscription hangs off an access token —
  but the crypto was never Mastodon-specific, only the caller was, and the
  installed web app has no token to hang anything off (issue #1729). So it
  lives here, and `Vutuv.MastodonApi.WebPush` is the thin delegating module the
  phone-client adapter keeps for its own switch.

  **Deliberately no dependency.** The obvious hex package,
  `web_push_encryption`, requires `httpoison ~> 1.0` — the HTTP client this
  project bans (see CLAUDE.md) — and has not shipped since 2021, so taking it
  would pin an ancient second HTTP stack beside `Req` to get a few hundred
  lines of standard crypto. Everything below is in OTP's `:crypto`: ECDH on
  `prime256v1`, HKDF built from `:crypto.mac/4`, and AES-128-GCM. Delivery goes
  through `Req` like every other outbound call.

  A push carries **no content**. The payload names the kind of thing that
  happened and which one, and nothing else, so a push service — and anything
  reading the phone's lock screen — learns that something happened, never what
  was said. A phone client fetches the notification itself over the
  authenticated API. That rule is why this module is worth sharing rather than
  copying: it will matter more for the installed app than it does for a
  third-party client, because there the result lands on a lock screen with our
  own name on it.

  **The key pair is this installation's own**, and nobody issues it: VAPID is a
  self-signed identity, so a server that has none can simply make one. That is
  what happens here when the operator configured nothing — the pair is derived
  from `secret_key_base`, exactly as the login-PIN pepper is, so every node of
  an installation computes the same one without a table, a migration or a
  shared file, and two installations never share a key. Requiring an env var
  first made push a feature nobody switched on: an operator who never read the
  manual had clients answering "push is not configured" forever
  (`WEB_PUSH_ENABLED=false` is the deliberate off switch for an intranet that
  must not reach a push service; see `docs/ADMINS.md`).

  `VAPID_PUBLIC_KEY`/`VAPID_PRIVATE_KEY` still win where they are set — both or
  neither, since half a pair is a signature no push service will accept — which
  is what an operator who rotates `secret_key_base` wants, and what carries a
  key pair across a move to another installation.
  """

  # `push/2` calls this module's own `send/2`, which Elixir would otherwise read
  # as `Kernel.send/2`. Nothing here sends a message to a process.
  import Kernel, except: [send: 2]

  require Logger

  alias Vutuv.Repo
  alias Vutuv.Ssrf
  alias VutuvWeb.Endpoint

  @curve :prime256v1
  @jwt_ttl_seconds 12 * 3600

  # The order of P-256's base point. A derived scalar has to land inside it to
  # be a private key at all; the odds of missing are about 2^-32, but "about"
  # is not a thing to leave in a boot path.
  @p256_order 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

  @doc """
  Whether this installation sends pushes at all. There is no "not configured"
  state left (see the moduledoc), so this is the operator's one switch, and it
  is deliberately **not** the phone-client adapter's: the installed web app
  pushes through this module without ever touching the Mastodon API, so
  `MASTODON_API_ENABLED=false` must not silence a member's own phone.
  `Vutuv.MastodonApi.WebPush` adds that gate for its own callers.
  """
  def enabled?, do: Application.get_env(:vutuv, :web_push_enabled, true)

  @doc "The VAPID public key a client needs to create a subscription."
  def public_key, do: if(enabled?(), do: elem(keys(), 0))

  # RFC 8292 wants a way to reach whoever runs this server, and a push service
  # is entitled to refuse a JWT without one — so the placeholder address this
  # used to fall back to was worse than no default at all. `operator_email/0`
  # is the adapter's own answer to "how do you reach whoever runs this", the
  # one `security.txt` publishes.
  defp subject, do: config(:vapid_subject) || "mailto:" <> operator_email()

  defp operator_email do
    {_name, email} = Application.fetch_env!(:vutuv, :operator_recipient)
    email
  end

  # Both halves or neither: an installation whose env carries a public key
  # without its private one would advertise a key it cannot sign with, and
  # every push would be refused by the push service with nothing in our log to
  # say why.
  defp keys do
    case {config(:vapid_public_key), config(:vapid_private_key)} do
      {public, private} when is_binary(public) and is_binary(private) -> {public, private}
      _incomplete_or_absent -> derived_keys()
    end
  end

  # 45µs, and its only input cannot change while a node runs, so a memo keyed
  # on the secret would be correct — it just has to sit here rather than around
  # `keys/0`, where it would freeze a pair an operator pins later.
  #
  # Not worth a `:persistent_term` write while the only caller is a push that
  # is already going out over the network. Watch this when `public_key/0`
  # gains a caller on a **render** path rather than a send path — the installed
  # app (issue #1729) needs it to draw its subscribe switch, which would make
  # this once per page view per member instead of once per push. Memoise then,
  # rather than re-reading this comment as though it still said "once per push".
  defp derived_keys(counter \\ 0) do
    candidate =
      :crypto.hash(:sha256, "vutuv/web_push/vapid/v1/#{counter}" <> secret_key_base())

    case candidate do
      <<scalar::unsigned-big-256>> when scalar > 0 and scalar < @p256_order ->
        {public, private} = :crypto.generate_key(:ecdh, @curve, candidate)
        {encode(public), encode(private)}

      _outside_the_curve_order ->
        derived_keys(counter + 1)
    end
  end

  defp secret_key_base do
    Application.fetch_env!(:vutuv, Endpoint)[:secret_key_base]
  end

  defp config(key) do
    case Application.get_env(:vutuv, :web_push, [])[key] do
      value when is_binary(value) and value != "" -> value
      _absent -> nil
    end
  end

  @doc """
  Sends one push and acts on the answer: a subscription the push service
  reports as dead is deleted, anything else that failed is logged.

  **The delete is the whole reason this exists rather than `send/2` alone.** A
  push service reporting `404`/`410` is the only signal that a browser cleared
  its site data or the app was uninstalled, and acting on it here is what keeps
  both subscription lists clean without a sweeper. Left to the callers it was a
  contract stated in a docstring and implemented twice by hand — and a third
  caller would have had to remember it from prose.

  Both subscription schemas are ordinary Ecto structs, so one `Repo.delete/1`
  serves the phone-client rows and the installed app's alike.
  """
  def push(subscription, payload) do
    case send(subscription, payload) do
      :ok ->
        :ok

      # `allow_stale`, because two notifications a second apart are two tasks
      # pushing to the same dead subscription: both are answered 410, and the
      # second `Repo.delete/1` would find no row and raise
      # `Ecto.StaleEntryError`. Deleting what is already deleted is exactly
      # what this branch means.
      {:error, :gone} ->
        Repo.delete(subscription, allow_stale: true)
        :ok

      # A push nobody asked for is not a failure worth a line in the log: an
      # installation with `WEB_PUSH_ENABLED=false` would otherwise write one
      # per device per notification, for ever.
      {:error, :disabled} ->
        :ok

      {:error, reason} ->
        Logger.warning("web push failed: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Sends one push. Answers `:ok`, or `{:error, :gone}` when the subscription is
  dead. Prefer `push/2`, which acts on that answer; this is the bare transport.
  """
  def send(%{endpoint: endpoint, p256dh: p256dh, auth: auth}, payload) do
    if enabled?() do
      deliver(endpoint, p256dh, auth, Jason.encode!(payload))
    else
      {:error, :disabled}
    end
  end

  defp deliver(endpoint, p256dh, auth, body) do
    with :ok <- check_target(endpoint),
         {:ok, ua_public} <- decode_key(p256dh),
         {:ok, auth_secret} <- decode_key(auth) do
      {encrypted, _salt} = encrypt(body, ua_public, auth_secret)

      case Req.post(endpoint, request_options(endpoint, encrypted)) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        {:ok, %{status: status}} when status in [404, 410] -> {:error, :gone}
        {:ok, %{status: status}} -> {:error, {:status, status}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :blocked} ->
        {:error, :blocked}

      # A tagged tuple, never the bare `:error` this `with` would otherwise fall
      # through with: the caller matches `{:error, reason}`, and a naked atom
      # crashed its `case` rather than being logged. The two subscription
      # changesets refuse such a key now, so this is the floor under rows
      # written before they did.
      _undecodable_key ->
        {:error, :invalid_key}
    end
  end

  # `:web_push_req_options` is the seam a test stubs the push service through
  # (a `plug:`, the convention this app already uses for `Vutuv.Mastodon` and
  # the fediverse fetches). Nothing sets it outside the test environment, so a
  # real send is exactly the request written here.
  defp request_options(endpoint, encrypted) do
    Keyword.merge(
      [
        body: encrypted,
        headers: [
          {"content-encoding", "aes128gcm"},
          {"content-type", "application/octet-stream"},
          {"ttl", "2419200"},
          {"urgency", "normal"},
          {"authorization", authorization(endpoint)}
        ],
        receive_timeout: 10_000,
        retry: false,
        # A push service has no business redirecting us, and following one would
        # walk straight around the check above: the vetted host answers 302 and
        # the next hop is wherever it likes. `Vutuv.Webhooks` refuses redirects
        # for the same reason.
        redirect: false
      ],
      Application.get_env(:vutuv, :web_push_req_options, [])
    )
  end

  # The resolving half of the SSRF pair. The changeset already refused an
  # internal *literal*, but a hostname that was public when the subscription was
  # written can be re-pointed at an internal address afterwards, and the whole
  # point of a stored-then-fetched URL is that those are two different moments
  # (`Vutuv.Webhooks` learned this as issue #775). Resolution failure is not
  # treated as internal: there is nothing to reach, so the POST fails on its own.
  defp check_target(endpoint) do
    if Ssrf.resolves_to_internal?(URI.parse(endpoint).host),
      do: {:error, :blocked},
      else: :ok
  end

  @doc """
  Decodes one of a subscription's base64url keys.

  Padded input is accepted beside bare, and the standard alphabet beside
  base64url: the keys are copied out of a browser's `PushManager` subscription
  by hand-written client code, and the operator's own VAPID private key is
  pasted in by a person. All of those spellings are in the wild, and the caller
  checks the decoded size anyway.
  """
  def decode_key(value) when is_binary(value) do
    trimmed = String.trim_trailing(value, "=")

    case Base.url_decode64(trimmed, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> Base.decode64(trimmed, padding: false)
    end
  end

  def decode_key(_value), do: :error

  @doc """
  RFC 8291 §3.4: one `aes128gcm` record, header and all. The whole point of the
  ceremony is that the key is derived from a shared secret **plus** the
  subscription's own `auth` secret, so a push service that relays the body
  cannot read it.

  `salt` and `keypair` exist so the ceremony can be checked against the test
  vector in RFC 8291 §5, which fixes both (see `web_push_test.exs`). Left out,
  they are fresh per message, which is what every real send does — a reused salt
  with a reused key would leak the plaintext.
  """
  def encrypt(plaintext, ua_public, auth_secret, salt \\ nil, keypair \\ nil) do
    salt = salt || :crypto.strong_rand_bytes(16)
    {as_public, as_private} = keypair || :crypto.generate_key(:ecdh, @curve)
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
    # One derivation, not two: both halves come out of the same tuple, and a
    # member with three phones pays this per device per notification.
    {public, private} = keys()
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
    signature = encode(sign(signing_input, private))

    "vapid t=#{signing_input}.#{signature}, k=#{public}"
  end

  defp sign(message, private_key) do
    {:ok, private} = decode_key(private_key)

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

  @doc """
  A fresh VAPID key pair as the two base64url strings an operator puts in the
  environment. Nothing needs it — an installation derives its own pair — but it
  is how an operator pins one that outlives a `secret_key_base` rotation. Run
  it once with `mix run -e`, keep the private key secret.
  """
  def generate_keys do
    {public, private} = :crypto.generate_key(:ecdh, @curve)
    %{public_key: encode(public), private_key: encode(private)}
  end
end
