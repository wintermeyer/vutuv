defmodule Vutuv.WebPushTest do
  @moduledoc """
  The Web Push payload encryption, against the test vectors both encodings
  publish: **RFC 8291 §5** for `aes128gcm`, and
  **draft-ietf-webpush-encryption-04 §5** for the `aesgcm` the phone clients
  need (issue #1698).

  This is the one piece of the adapter written from a specification rather than
  from a running implementation to copy, and it is also the piece whose failure
  is silent in the worst way: a push service accepts a body it cannot read and
  answers 201, so a subtly wrong key derivation ships as "push does not work on
  some phones" and nothing in a log says why. The spec publishes fixed inputs
  and the exact expected output, so the whole ceremony — ECDH, the two HKDF
  steps with `WebPush: info`, the record delimiter, the header — is checked in
  one comparison.

  `salt` and the sender key pair are injected for exactly this reason; a real
  send draws both fresh, which one test here asserts.

  Which of the two a send uses is the subscription's `standard` flag, and that
  is checked through `send/2` itself rather than by reading a private function:
  the encoding is only half of it, since `aesgcm` is unopenable without the
  `Encryption:` and `Crypto-Key:` headers that carry what its record leaves
  out.

  `async: false` because the `enabled?/0` group flips `:web_push_enabled` and
  `:web_push`, both global and both read by every push path in the app —
  `Vutuv.MastodonApi.PushDispatcher` gates on them, and
  `push_streaming_test.exs` is sync for the same reason.
  """
  use ExUnit.Case, async: false

  alias Vutuv.WebPush

  # RFC 8291 §5, verbatim.
  @plaintext "When I grow up, I want to be a watermelon"
  @ua_public "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
  @auth_secret "BTBZMqHH6r4Tts7J_aSIgg"
  @as_public "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
  @as_private "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"
  @salt "DGv6ra1nlYgDCS1FRnbzlw"
  @expected_body "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"

  # draft-ietf-webpush-encryption-04 §5 and Appendix A, verbatim. Its own keys,
  # not RFC 8291's — a different example entirely.
  @legacy_plaintext "I am the walrus"
  @legacy_ua_public "BCEkBjzL8Z3C-oi2Q7oE5t2Np-p7osjGLg93qUP0wvqRT21EEWyf0cQDQcakQMqz4hQKYOQ3il2nNZct4HgAUQU"
  @legacy_ua_private "9FWl15_QUQAWDaD3k3l50ZBZQJ4au27F1V4F0uLSD_M"
  @legacy_auth_secret "R29vIGdvbyBnJyBqb29iIQ"
  @legacy_as_public "BNoRDbb84JGm8g5Z5CFxurSqsXWJ11ItfXEWYVLE85Y7CYkDjXsIEc4aqxYaQ1G8BqkXCJ6DPpDrWtdWj_mugHU"
  @legacy_as_private "nCScek-QpEjmOOlT-rQ38nZzvdPlqa00Zy0i6m2OJvY"
  @legacy_salt "lngarbyKfMoi9Z75xYXmkg"
  @legacy_ciphertext "6nqAQUME8hNqw5J3kl8cpVVJylXKYqZOeseZG8UueKpA"

  test "encrypts the RFC 8291 example to the byte the RFC prints" do
    assert Base.url_encode64(rfc_body(), padding: false) == @expected_body
  end

  test "the header carries the salt, the record size and the sender's key" do
    <<salt::binary-size(16), record_size::unsigned-big-32, key_length::unsigned-8,
      as_public::binary-size(key_length), _record::binary>> = rfc_body()

    assert salt == decode!(@salt)
    assert record_size == 4096
    # An uncompressed P-256 point: 0x04 and the two 32-byte coordinates.
    assert key_length == 65
    assert as_public == decode!(@as_public)
  end

  # A reused salt under a reused key is the classic AES-GCM failure, and here the
  # key is derived from the salt — so two sends of the same payload to the same
  # subscription must not produce the same bytes.
  test "draws a fresh salt and key pair when none is given" do
    args = [@plaintext, decode!(@ua_public), decode!(@auth_secret)]

    {first, first_salt} = apply(WebPush, :encrypt, args)
    {second, second_salt} = apply(WebPush, :encrypt, args)

    refute first_salt == second_salt
    refute first == second
  end

  test "encrypts the draft's aesgcm example to the byte the draft prints" do
    {body, salt, as_public} =
      WebPush.encrypt_aesgcm(
        @legacy_plaintext,
        decode!(@legacy_ua_public),
        decode!(@legacy_auth_secret),
        decode!(@legacy_salt),
        {decode!(@legacy_as_public), decode!(@legacy_as_private)}
      )

    assert Base.url_encode64(body, padding: false) == @legacy_ciphertext
    # The two values this record does *not* carry, which is the whole reason
    # the encoding needs headers beside it.
    assert salt == decode!(@legacy_salt)
    assert as_public == decode!(@legacy_as_public)
  end

  describe "send/2" do
    setup do
      put_config(:web_push_enabled, true)

      test = self()

      # An `adapter:` and not the `plug:` seam the other outbound clients are
      # stubbed with, because **Req's plug adapter deletes the request's
      # `content-encoding` header**: it reads that header as transport
      # compression, decompresses the body with it and drops it before the plug
      # ever sees the conn. Here the header is not transport at all, it is the
      # payload's own encoding and the whole subject of this test — so the stub
      # has to sit one step earlier, where what would go on the wire is still
      # intact.
      put_config(:web_push_req_options,
        adapter: fn request ->
          send(test, {:pushed, request})
          {request, %Req.Response{status: 201, body: ""}}
        end
      )

      :ok
    end

    # The bug in issue #1698: an iOS client subscribes through an APNs relay,
    # which can only pass on what stands in a header. `aes128gcm` keeps the salt
    # and the sender key inside the body, so the phone is handed a record it has
    # no keys for and shows "Unable to decrypt notification".
    test "a subscription that never opted in gets aesgcm, salt and key in headers" do
      assert WebPush.send(subscription(false), %{a: 1}) == :ok

      assert_receive {:pushed, request}
      assert header(request, "content-encoding") == "aesgcm"
      assert "salt=" <> salt = header(request, "encryption")
      assert "dh=" <> as_public = header(request, "crypto-key")

      # Unpadded base64url, and unquoted whatever the draft's own example
      # prints: a relay reads these with a raw base64url decoder, and a `=` or a
      # `"` is what makes it hand the phone nothing.
      assert {:ok, salt} = Base.url_decode64(salt, padding: false)
      assert {:ok, as_public} = Base.url_decode64(as_public, padding: false)

      # And the two really do open this body — the assertion the encoding itself
      # cannot make, since a header naming the wrong salt or the wrong key is a
      # push the service still answers 201 to.
      assert decrypt_aesgcm(request.body, salt, as_public) == ~s({"a":1})
    end

    test "a subscription that opted in gets aes128gcm and no encoding headers" do
      assert WebPush.send(subscription(true), %{a: 1}) == :ok

      assert_receive {:pushed, request}
      assert header(request, "content-encoding") == "aes128gcm"
      refute header(request, "encryption")
      refute header(request, "crypto-key")

      # Nothing was left out: this record carries its own salt and key.
      assert <<_salt::binary-size(16), 4096::unsigned-big-32, 65::unsigned-8, _rest::binary>> =
               request.body
    end

    # Issue #1729 landed while this was open and brought a second subscription
    # kind that carries no flag at all. It talks to the browser's real push
    # service with no relay in between, so it must get the standard encoding —
    # falling into the legacy catch-all would hand this installation's own app
    # a body built for somebody else's relay, and every test would stay green.
    test "the installation's own app subscription gets aes128gcm" do
      subscription = %Vutuv.WebPush.Subscription{
        endpoint: "https://push.example.invalid/1",
        p256dh: @legacy_ua_public,
        auth: @legacy_auth_secret
      }

      assert WebPush.content_encoding(subscription) == :aes128gcm
      assert WebPush.send(subscription, %{a: 1}) == :ok

      assert_receive {:pushed, request}
      assert header(request, "content-encoding") == "aes128gcm"
      refute header(request, "crypto-key")
    end

    # `PushDispatcher` hands over the row, but a caller with a plain map is a
    # shape this module accepts, and "no flag" has to read the same as "false"
    # or a device would quietly be sent a body it cannot open.
    test "a subscription map without the flag is read as legacy" do
      assert WebPush.send(Map.delete(subscription(false), :standard), %{a: 1}) == :ok

      assert_receive {:pushed, request}
      assert header(request, "content-encoding") == "aesgcm"
    end
  end

  describe "enabled?/0" do
    setup do
      for key <- [:web_push, :web_push_enabled], do: keep_config(key)

      :ok
    end

    # An installation that configured nothing is the ordinary case, not a
    # broken one: it derives its own pair, so push works and this stays true.
    # Requiring the two env vars is what left every client on vutuv.de unable
    # to switch push on.
    test "is true on an installation that configured nothing" do
      Application.put_env(:vutuv, :web_push_enabled, true)
      Application.put_env(:vutuv, :web_push, [])

      assert WebPush.enabled?()
      assert is_binary(WebPush.public_key())
    end

    # An intranet installation cannot reach a push service, so there has to be
    # a switch — just not one an operator has to find in order to get the
    # feature everybody else wants.
    test "is false only where the operator turned push off" do
      Application.put_env(:vutuv, :web_push_enabled, false)

      refute WebPush.enabled?()
      refute WebPush.public_key()
    end

    # The reason this module was lifted out of the Mastodon adapter (issue
    # #1729): a member's own installed app pushes through here without ever
    # touching the phone-client API, so switching that adapter off must not
    # silence their phone. `Vutuv.MastodonApi.WebPush` keeps the narrower gate
    # for its own callers, which `push_streaming_test.exs` pins.
    test "is unaffected by the phone-client adapter's own switch" do
      Application.put_env(:vutuv, :web_push_enabled, true)
      original = Application.fetch_env(:vutuv, :mastodon_api_enabled)
      Application.put_env(:vutuv, :mastodon_api_enabled, false)

      on_exit(fn ->
        case original do
          {:ok, was} -> Application.put_env(:vutuv, :mastodon_api_enabled, was)
          :error -> Application.delete_env(:vutuv, :mastodon_api_enabled)
        end
      end)

      assert WebPush.enabled?()
      assert is_binary(WebPush.public_key())
      refute Vutuv.MastodonApi.WebPush.enabled?()
    end

    test "an installation with push off refuses to send rather than trying" do
      Application.put_env(:vutuv, :web_push_enabled, false)

      subscription = %{
        endpoint: "https://push.example/1",
        p256dh: @ua_public,
        auth: @auth_secret
      }

      assert WebPush.send(subscription, %{a: 1}) == {:error, :disabled}
    end
  end

  test "generate_keys/0 answers a pair this module then accepts as configured" do
    %{public_key: public, private_key: private} = WebPush.generate_keys()

    assert byte_size(decode!(public)) == 65
    assert byte_size(decode!(private)) == 32
  end

  # -- helpers --------------------------------------------------------------

  defp decode!(value) do
    {:ok, decoded} = Base.url_decode64(value, padding: false)
    decoded
  end

  defp rfc_body do
    {body, _salt} =
      WebPush.encrypt(
        @plaintext,
        decode!(@ua_public),
        decode!(@auth_secret),
        decode!(@salt),
        {decode!(@as_public), decode!(@as_private)}
      )

    body
  end

  defp header(request, name), do: List.first(Req.Request.get_header(request, name))

  defp subscription(standard) do
    %{
      endpoint: "https://push.example.invalid/1",
      p256dh: @legacy_ua_public,
      auth: @legacy_auth_secret,
      standard: standard
    }
  end

  # The receiving half of draft-ietf-webpush-encryption-04 §3, written out here
  # rather than borrowed from the module under test: this is the phone's side of
  # the exchange, and the point of the assertion above is that what our headers
  # carry is enough for somebody who only has the subscription's own keys.
  defp decrypt_aesgcm(body, salt, as_public) do
    size = byte_size(body) - 16
    <<ciphertext::binary-size(^size), tag::binary-size(16)>> = body

    ua_public = decode!(@legacy_ua_public)
    shared = :crypto.compute_key(:ecdh, as_public, decode!(@legacy_ua_private), :prime256v1)
    ikm = hkdf(decode!(@legacy_auth_secret), shared, "Content-Encoding: auth" <> <<0>>, 32)

    context =
      "P-256" <> <<0, 65::unsigned-big-16>> <> ua_public <> <<65::unsigned-big-16>> <> as_public

    cek = hkdf(salt, ikm, "Content-Encoding: aesgcm" <> <<0>> <> context, 16)
    nonce = hkdf(salt, ikm, "Content-Encoding: nonce" <> <<0>> <> context, 12)

    <<pad::unsigned-big-16, padded::binary>> =
      :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, ciphertext, <<>>, tag, false)

    binary_part(padded, pad, byte_size(padded) - pad)
  end

  defp hkdf(salt, ikm, info, length) do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    binary_part(:crypto.mac(:hmac, :sha256, prk, info <> <<1>>), 0, length)
  end

  # `Application.fetch_env/2`, never `get_env/2`: a key this file deletes must
  # come back deleted, not written back as a real `nil` (`:web_push_enabled`
  # defaults to true where it is absent, so a stored `nil` is not the same
  # thing at all).
  defp keep_config(key) do
    original = Application.fetch_env(:vutuv, key)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, key, was)
        :error -> Application.delete_env(:vutuv, key)
      end
    end)
  end

  defp put_config(key, value) do
    keep_config(key)
    Application.put_env(:vutuv, key, value)
  end
end
