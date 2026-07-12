defmodule Vutuv.Invitations.PrefillTokenTest do
  use ExUnit.Case, async: true

  alias Vutuv.Invitations.PrefillToken

  @full %{
    "gender" => "female",
    "first_name" => "Jane",
    "last_name" => "Doe",
    "email" => "jane@example.com",
    "tags" => "Elixir, Cooking"
  }

  describe "encode/1 + decode/1 round-trip" do
    test "recovers every field" do
      assert @full |> PrefillToken.encode() |> PrefillToken.decode() == @full
    end

    test "recovers a partial prefill and omits the blank fields" do
      partial = %{"first_name" => "Jane", "email" => "jane@example.com"}
      assert partial |> PrefillToken.encode() |> PrefillToken.decode() == partial
    end

    test "round-trips umlauts, hyphens and separators inside tags" do
      prefill = %{
        "first_name" => "Müller-Lüdenscheidt",
        "last_name" => "Fußball",
        "email" => "maximilian.mueller@musterfirma-hamburg.de",
        "tags" => "Softwareentwicklung, Fußball, Kochen"
      }

      assert prefill |> PrefillToken.encode() |> PrefillToken.decode() == prefill
    end

    test "returns nil when every field is blank" do
      assert PrefillToken.encode(%{"gender" => nil, "first_name" => "", "email" => nil}) == nil
    end
  end

  describe "decode/1 is total — a bad token never raises" do
    test "empty or non-binary input yields an empty prefill" do
      assert PrefillToken.decode("") == %{}
      assert PrefillToken.decode(nil) == %{}
    end

    test "input that is not valid base64url yields an empty prefill" do
      assert PrefillToken.decode("!!! not base64 !!!") == %{}
    end

    test "valid base64 that is not valid DEFLATE yields an empty prefill" do
      assert "plain text" |> Base.url_encode64(padding: false) |> PrefillToken.decode() == %{}
    end

    test "an oversized token is rejected before inflating (decompression-bomb guard)" do
      # A real token is well under 1 KB; a larger `i=` param is refused up front
      # rather than inflated (raw DEFLATE reaches ~1000:1).
      bomb = String.duplicate("A", 2000)
      assert PrefillToken.decode(bomb) == %{}
    end
  end

  describe "query/1 picks the shorter encoding" do
    test "a real invite (which always has a name) is shorter as a token and hides the PII" do
      query = PrefillToken.query(@full)

      assert String.starts_with?(query, "i=")
      refute query =~ "jane%40example.com"
      refute query =~ "first_name"

      spelled_out = URI.encode_query(Enum.sort(@full))
      assert String.length(query) < String.length(spelled_out)
    end

    test "falls back to spelled-out params when the token would be longer" do
      # A single tiny field: the token's DEFLATE + base64 overhead loses to a
      # plain key=value pair, so we keep the plain form (never make a link longer).
      assert PrefillToken.query(%{"email" => "a@b.de"}) == "email=a%40b.de"
    end

    test "is an empty string when there is nothing to prefill" do
      assert PrefillToken.query(%{"gender" => nil, "first_name" => ""}) == ""
    end
  end
end
