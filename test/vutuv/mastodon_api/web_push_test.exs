defmodule Vutuv.MastodonApi.WebPushTest do
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

  `async: false` because the `configured?/0` group flips the `:web_push`
  application config, which is global and which every push path in the app
  reads — `Vutuv.MastodonApi.PushDispatcher` gates on it, and
  `push_streaming_test.exs` is sync for the same reason.
  """
  use ExUnit.Case, async: false

  alias Vutuv.MastodonApi.WebPush

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

  describe "configured?/0" do
    setup do
      original = Application.fetch_env(:vutuv, :web_push)

      on_exit(fn ->
        case original do
          {:ok, value} -> Application.put_env(:vutuv, :web_push, value)
          :error -> Application.delete_env(:vutuv, :web_push)
        end
      end)

      :ok
    end

    # An intranet installation cannot reach a push service, so this has to be a
    # switch that is off until an operator sets both keys — not a best effort
    # that times out against the internet on every notification.
    test "is false until both VAPID keys are set" do
      Application.put_env(:vutuv, :web_push, [])
      refute WebPush.configured?()

      Application.put_env(:vutuv, :web_push, vapid_public_key: @as_public)
      refute WebPush.configured?()

      Application.put_env(:vutuv, :web_push,
        vapid_public_key: @as_public,
        vapid_private_key: @as_private
      )

      assert WebPush.configured?()
    end

    test "an unconfigured installation refuses to send rather than trying" do
      Application.put_env(:vutuv, :web_push, [])

      subscription = %{
        endpoint: "https://push.example/1",
        p256dh: @ua_public,
        auth: @auth_secret
      }

      assert WebPush.send(subscription, %{a: 1}) == {:error, :not_configured}
    end
  end

  test "generate_keys/0 answers a pair this module then accepts as configured" do
    %{public_key: public, private_key: private} = WebPush.generate_keys()

    assert byte_size(decode!(public)) == 65
    assert byte_size(decode!(private)) == 32
  end
end
