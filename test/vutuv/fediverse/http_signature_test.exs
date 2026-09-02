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
                   body: body,
                   hosts: ["mastodon.example"]
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
                 %{
                   method: "get",
                   path: "/users/alice",
                   headers: header_map,
                   body: nil,
                   hosts: ["mastodon.example"]
                 },
                 pub
               )
    end

    # `nil` on a POST means the raw bytes were never captured, not that there was
    # nothing to hash. Verifying anyway drops `digest` from the required header
    # list and makes `check_digest/2` answer `:ok`, so the signature would vouch
    # for the headers alone and any payload could ride them — which is what the
    # organization and tag inboxes did until `VutuvWeb.RawBodyReader` learned
    # their path shapes. It fails closed so the next route added without a
    # reader clause is refused rather than trusted.
    test "a POST whose body was never captured is refused", %{
      priv: priv,
      pub: pub,
      key_id: key_id
    } do
      headers =
        HttpSignature.signed_headers("post", "https://m.example/inbox", "payload", key_id, priv)

      assert {:error, :body_not_captured} ==
               HttpSignature.valid?(
                 %{
                   method: "post",
                   path: "/inbox",
                   headers: Map.new(headers),
                   body: nil,
                   hosts: ["m.example"]
                 },
                 pub
               )
    end

    # `(request-target)` is the PATH, not the destination, so a signature over
    # it alone says nothing about which installation the delivery was addressed
    # to. Two vutuv installations share the inbox path, so the exact bytes one
    # receives verify at the other inside the 12-hour date window, and the
    # sender's activity runs there as if she had addressed it — a Create cached,
    # an Announce recorded, a Move or Delete processed.
    #
    # Requiring `host` in the signed set only guarantees the value is covered by
    # the signature; it does not say the value names US. The replay does not
    # rewrite the header — that would break the signature and is the one thing an
    # attacker has no reason to do. He keeps `Host: first.example` and posts the
    # same bytes at the second installation, whose inbox path is identical: the
    # signing string rebuilds from the header he sent, so it matches.
    #
    # So the destination has to be CHECKED, not merely signed, against a host
    # this installation actually answers on — a value from configuration, never
    # from the request (`conn.host` is that same header).
    test "a delivery addressed to another installation is refused", %{
      priv: priv,
      pub: pub,
      key_id: key_id
    } do
      body = ~s({"type":"Create"})

      headers =
        HttpSignature.signed_headers(
          "post",
          "https://first.example/system/inbox",
          body,
          key_id,
          priv
        )
        |> Map.new()

      # Authentic at the installation it names.
      assert :ok ==
               HttpSignature.valid?(
                 %{
                   method: "post",
                   path: "/system/inbox",
                   headers: headers,
                   body: body,
                   hosts: ["first.example"]
                 },
                 pub
               )

      # The same bytes, unaltered, offered to a second installation.
      assert {:error, :wrong_destination} ==
               HttpSignature.valid?(
                 %{
                   method: "post",
                   path: "/system/inbox",
                   headers: headers,
                   body: body,
                   hosts: ["second.example"]
                 },
                 pub
               )
    end

    test "a request that names no acceptable destination is refused", %{
      priv: priv,
      pub: pub,
      key_id: key_id
    } do
      body = ~s({"type":"Create"})

      headers =
        HttpSignature.signed_headers(
          "post",
          "https://first.example/system/inbox",
          body,
          key_id,
          priv
        )
        |> Map.new()

      # Fails closed: a caller that forgets to say where the delivery arrived
      # gets a refusal, not a pass.
      assert {:error, :wrong_destination} ==
               HttpSignature.valid?(
                 %{method: "post", path: "/system/inbox", headers: headers, body: body},
                 pub
               )
    end

    test "a sender that leaves the destination unsigned is refused", %{
      priv: priv,
      pub: pub,
      key_id: key_id
    } do
      body = ~s({"type":"Create"})

      headers =
        HttpSignature.signed_headers(
          "post",
          "https://first.example/system/inbox",
          body,
          key_id,
          priv
        )
        |> Map.new()

      # A signature whose header list omits `host`: nothing in the signed string
      # names where the delivery was going, so it is replayable by construction.
      unbound =
        put_in(
          headers["signature"],
          String.replace(
            headers["signature"],
            "headers=\"(request-target) host date digest\"",
            "headers=\"(request-target) date digest\""
          )
        )

      request = %{method: "post", path: "/system/inbox", headers: unbound, body: body}

      assert {:error, :unsigned_required_header} == HttpSignature.valid?(request, pub)
    end

    test "a tampered body is rejected (digest mismatch)", %{priv: priv, pub: pub, key_id: key_id} do
      headers =
        HttpSignature.signed_headers("post", "https://m.example/inbox", "original", key_id, priv)

      assert {:error, :digest_mismatch} ==
               HttpSignature.valid?(
                 %{
                   method: "post",
                   path: "/inbox",
                   headers: Map.new(headers),
                   body: "tampered",
                   hosts: ["m.example"]
                 },
                 pub
               )
    end

    test "a tampered header is rejected", %{priv: priv, pub: pub, key_id: key_id} do
      headers =
        HttpSignature.signed_headers("post", "https://m.example/inbox", "x", key_id, priv)

      tampered = headers |> Map.new() |> Map.put("date", "Thu, 01 Jan 2026 00:00:00 GMT")

      assert {:error, _reason} =
               HttpSignature.valid?(
                 %{
                   method: "post",
                   path: "/inbox",
                   headers: tampered,
                   body: "x",
                   hosts: ["m.example"]
                 },
                 pub
               )
    end

    test "the wrong key is rejected", %{priv: priv, key_id: key_id} do
      {_other_priv, other_pub} = Keys.generate()

      headers =
        HttpSignature.signed_headers("post", "https://m.example/inbox", "x", key_id, priv)

      assert {:error, :invalid_signature} ==
               HttpSignature.valid?(
                 %{
                   method: "post",
                   path: "/inbox",
                   headers: Map.new(headers),
                   body: "x",
                   hosts: ["m.example"]
                 },
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
                 %{
                   method: "post",
                   path: "/inbox",
                   headers: Map.new(headers),
                   body: "x",
                   hosts: ["m.example"]
                 },
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
                 %{
                   method: "post",
                   path: "/inbox",
                   headers: Map.new(headers),
                   body: "x",
                   hosts: ["m.example"]
                 },
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
