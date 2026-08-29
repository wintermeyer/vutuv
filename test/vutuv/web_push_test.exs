defmodule Vutuv.WebPushTest do
  @moduledoc """
  The Web Push payload encryption, against the test vector in **RFC 8291 §5**.

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

  describe "enabled?/0" do
    setup do
      for key <- [:web_push, :web_push_enabled] do
        original = Application.fetch_env(:vutuv, key)

        on_exit(fn ->
          case original do
            {:ok, value} -> Application.put_env(:vutuv, key, value)
            :error -> Application.delete_env(:vutuv, key)
          end
        end)
      end

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
end
