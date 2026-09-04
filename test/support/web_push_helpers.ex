defmodule Vutuv.WebPushHelpers do
  @moduledoc """
  The one copy of the Web Push test fixtures (issue #1729).

  The **subscription keys are the RFC 8291 §5 vector**, not placeholders:
  `Vutuv.WebPush.Validations` decodes both and checks their exact byte length,
  so an invented string is refused for the wrong reason and the test then
  passes or fails for something other than what it names. Three files needed
  them, which is two too many to keep in step by hand.
  """

  # RFC 8291 §5: base64url of a 65-byte P-256 point and a 16-byte secret.
  @p256dh "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
  @auth "BTBZMqHH6r4Tts7J_aSIgg"

  def p256dh, do: @p256dh
  def auth, do: @auth

  @doc "A browser's own `PushSubscription.toJSON()`, which is what the page posts."
  def subscription_json(endpoint \\ "https://push.example.com/abcdef") do
    %{"endpoint" => endpoint, "keys" => %{"p256dh" => @p256dh, "auth" => @auth}}
  end

  @doc "The three values `Vutuv.WebPush.Subscriptions.subscribe/3` stores."
  def subscription_attrs(endpoint) do
    %{"endpoint" => endpoint, "p256dh" => @p256dh, "auth" => @auth}
  end

  @curve :prime256v1

  @doc """
  A subscriber whose payloads a test can actually READ, as
  `%{attrs:, public:, private:, auth:}`.

  `p256dh/0` above is the RFC 8291 vector and its private half is not part of
  it, so nothing sent to that subscription can ever be opened again — which is
  why the payload test that used it could only assert that some word is absent
  from a ciphertext, a thing that is true of every ciphertext. This mints a
  fresh pair, and `decrypt_push/2` then reads the same bytes the browser hands
  the service worker.
  """
  def subscriber(endpoint) do
    {public, private} = :crypto.generate_key(:ecdh, @curve)
    auth = :crypto.strong_rand_bytes(16)

    %{
      public: public,
      private: private,
      auth: auth,
      attrs: %{
        "endpoint" => endpoint,
        "p256dh" => Base.url_encode64(public, padding: false),
        "auth" => Base.url_encode64(auth, padding: false)
      }
    }
  end

  @doc """
  The decoded payload of one `aes128gcm` push body (RFC 8291 §3.4) — the exact
  mirror of `Vutuv.WebPush.encrypt/5`, kept here rather than in the app because
  only a subscriber ever decrypts, and this installation never is one.
  """
  def decrypt_push(body, %{public: ua_public, private: ua_private, auth: auth}) do
    <<salt::binary-16, _rs::unsigned-big-32, key_len::unsigned-8, rest::binary>> = body
    <<as_public::binary-size(^key_len), sealed::binary>> = rest

    shared = :crypto.compute_key(:ecdh, as_public, ua_private, @curve)
    key_info = "WebPush: info" <> <<0>> <> ua_public <> as_public
    ikm = hkdf(auth, shared, key_info, 32)
    cek = hkdf(salt, ikm, "Content-Encoding: aes128gcm" <> <<0>>, 16)
    nonce = hkdf(salt, ikm, "Content-Encoding: nonce" <> <<0>>, 12)

    body_len = byte_size(sealed) - 16
    <<ciphertext::binary-size(^body_len), tag::binary-16>> = sealed

    padded = :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, ciphertext, <<>>, tag, false)

    # 0x02 is the record delimiter of the last record, which is the only one.
    plaintext_len = byte_size(padded) - 1
    <<plaintext::binary-size(^plaintext_len), 2>> = padded

    Jason.decode!(plaintext)
  end

  # RFC 5869 with the one-block expand every Web Push step needs; the same
  # function `Vutuv.WebPush` keeps private.
  defp hkdf(salt, ikm, info, length) do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    <<key::binary-size(^length), _rest::binary>> = :crypto.mac(:hmac, :sha256, prk, info <> <<1>>)
    key
  end

  @doc """
  Sets an application env for the test and restores it afterwards.

  `fetch_env/2` and not `get_env/2`: the latter answers `nil` both for "absent"
  and for "holds nil", so a naive restore writes `nil` back as a real value and
  every later reader gets it instead of the function's default (see CLAUDE.md).
  """
  def put_config(key, value) do
    original = Application.fetch_env(:vutuv, key)
    Application.put_env(:vutuv, key, value)

    ExUnit.Callbacks.on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, key, was)
        :error -> Application.delete_env(:vutuv, key)
      end
    end)
  end

  @doc """
  Answers every push with `status`, and reports each one to the test process as
  `{:pushed, request_path}`.

  Nothing here reaches the network: `:web_push_req_options` is the `plug:` seam
  this app already uses for `Vutuv.Mastodon` and the fediverse fetches, and
  `:ssrf_resolver` gives every hostname a public address so the send-time SSRF
  re-check answers the same way on every run and without a DNS lookup.
  """
  def stub_push_service(status \\ 201) do
    test = self()

    put_config(:web_push_req_options,
      plug: fn conn ->
        send(test, {:pushed, conn.request_path})
        Plug.Conn.send_resp(conn, status, "")
      end
    )

    put_config(:ssrf_resolver, fn _host, family ->
      if family == :inet, do: {:ok, [{93, 184, 216, 34}]}, else: {:error, :nxdomain}
    end)
  end
end
