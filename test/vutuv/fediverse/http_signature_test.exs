defmodule Vutuv.Fediverse.HttpSignatureTest do
  # draft-cavage HTTP Signatures, the de-facto Fediverse convention: every
  # inbox POST is signed with the sender's RSA key; Mastodon rejects unsigned
  # deliveries with a 401. Round-trips our signer against our verifier.
  use ExUnit.Case, async: true

  alias Vutuv.Fediverse.HttpSignature
  alias Vutuv.Fediverse.Keys

  setup do
    {priv, pub} = Keys.generate()
    %{priv: priv, pub: pub, key_id: "https://social.example/actor#main-key"}
  end

  describe "signed_headers/5 + valid?/2 round trip" do
    test "a signed POST with a body verifies", %{priv: priv, pub: pub, key_id: key_id} do
      body = ~s({"type":"Accept"})

      headers =
        HttpSignature.signed_headers(
          "post",
          "https://mastodon.example/users/alice/inbox",
          body,
          key_id,
          priv
        )

      header_map = Map.new(headers)
      assert header_map["host"] == "mastodon.example"
      assert header_map["digest"] =~ "SHA-256="
      assert header_map["signature"] =~ ~s(keyId="#{key_id}")

      assert :ok ==
               HttpSignature.valid?(
                 %{
                   method: "post",
                   path: "/users/alice/inbox",
                   headers: header_map,
                   body: body
                 },
                 pub
               )
    end

    test "a signed GET without a body verifies", %{priv: priv, pub: pub, key_id: key_id} do
      headers =
        HttpSignature.signed_headers(
          "get",
          "https://mastodon.example/users/alice",
          nil,
          key_id,
          priv
        )

      header_map = Map.new(headers)
      refute Map.has_key?(header_map, "digest")

      assert :ok ==
               HttpSignature.valid?(
                 %{method: "get", path: "/users/alice", headers: header_map, body: nil},
                 pub
               )
    end

    test "a tampered body is rejected (digest mismatch)", %{priv: priv, pub: pub, key_id: key_id} do
      headers =
        HttpSignature.signed_headers("post", "https://m.example/inbox", "original", key_id, priv)

      assert {:error, :digest_mismatch} ==
               HttpSignature.valid?(
                 %{method: "post", path: "/inbox", headers: Map.new(headers), body: "tampered"},
                 pub
               )
    end

    test "a tampered header is rejected", %{priv: priv, pub: pub, key_id: key_id} do
      headers =
        HttpSignature.signed_headers("post", "https://m.example/inbox", "x", key_id, priv)

      tampered = headers |> Map.new() |> Map.put("date", "Thu, 01 Jan 2026 00:00:00 GMT")

      assert {:error, _reason} =
               HttpSignature.valid?(
                 %{method: "post", path: "/inbox", headers: tampered, body: "x"},
                 pub
               )
    end

    test "the wrong key is rejected", %{priv: priv, key_id: key_id} do
      {_other_priv, other_pub} = Keys.generate()

      headers =
        HttpSignature.signed_headers("post", "https://m.example/inbox", "x", key_id, priv)

      assert {:error, :invalid_signature} ==
               HttpSignature.valid?(
                 %{method: "post", path: "/inbox", headers: Map.new(headers), body: "x"},
                 other_pub
               )
    end

    test "a non-numeric date is rejected, not raised", %{priv: priv, pub: pub, key_id: key_id} do
      # Signed over a malformed (attacker-controlled) date so the signature and
      # digest pass and check_date is actually reached: it must return an error,
      # not raise an ArgumentError that 500s the inbox.
      headers =
        HttpSignature.signed_headers("post", "https://m.example/inbox", "x", key_id, priv,
          date: "Xxx, 01 Jul abcd 00:00:00 GMT"
        )

      assert {:error, :bad_date} ==
               HttpSignature.valid?(
                 %{method: "post", path: "/inbox", headers: Map.new(headers), body: "x"},
                 pub
               )
    end

    test "a stale date is rejected", %{priv: priv, pub: pub, key_id: key_id} do
      stale =
        DateTime.utc_now()
        |> DateTime.add(-2, :day)
        |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

      headers =
        HttpSignature.signed_headers("post", "https://m.example/inbox", "x", key_id, priv,
          date: stale
        )

      assert {:error, :stale_date} ==
               HttpSignature.valid?(
                 %{method: "post", path: "/inbox", headers: Map.new(headers), body: "x"},
                 pub
               )
    end
  end

  describe "key_id/1" do
    test "extracts the keyId from a Signature header", %{priv: priv, key_id: key_id} do
      headers = HttpSignature.signed_headers("post", "https://m.example/inbox", "x", key_id, priv)

      assert HttpSignature.key_id(Map.new(headers)["signature"]) == {:ok, key_id}
    end

    test "rejects an unparsable header" do
      assert HttpSignature.key_id("garbage") == {:error, :no_key_id}
    end
  end

  describe "Keys" do
    test "generates a PEM pair Mastodon understands (SPKI public key)" do
      {priv, pub} = Keys.generate()

      assert priv =~ "-----BEGIN RSA PRIVATE KEY-----"
      assert pub =~ "-----BEGIN PUBLIC KEY-----"
    end
  end
end
