defmodule VutuvWeb.RawBodyReaderTest do
  @moduledoc """
  Which requests keep a copy of their raw body, and why it has to be every inbox.

  `Vutuv.Fediverse.HttpSignature.valid?/2` hashes the bytes as sent. Without
  them it used to drop `digest` from the headers it demands and let
  `check_digest/2` answer `:ok`, so an inbox with no captured body verified a
  signature over the headers alone and accepted any payload carrying them. The
  organization inbox (four path segments) and the tag inbox (two, on the `tags.`
  host) were in exactly that state, because the reader matched only the
  three-segment member inbox and `system/inbox`.

  This file pins the path shapes. The fail-closed half — that a POST with no
  captured body is refused outright — lives in
  `test/vutuv/fediverse/http_signature_test.exs`.
  """
  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 3]

  alias VutuvWeb.RawBodyReader

  @body ~s({"type":"Follow"})

  defp kept_body(path) do
    {:ok, @body, conn} = RawBodyReader.read_body(conn(:post, path, @body), [])
    RawBodyReader.raw_body(conn)
  end

  describe "every inbox route keeps its bytes" do
    test "a member's actor inbox" do
      assert kept_body("/alice/actor/inbox") == @body
    end

    test "a page's actor inbox" do
      assert kept_body("/organizations/acme/actor/inbox") == @body
    end

    test "the installation-wide inbox" do
      assert kept_body("/system/inbox") == @body
    end

    test "a topic's inbox, two segments on the tags host" do
      assert kept_body("/elixir/inbox") == @body
    end
  end

  describe "everything else streams through untouched" do
    test "an ordinary path pays no copy" do
      for path <- ["/feed", "/alice", "/alice/actor", "/organizations/acme", "/system"] do
        assert kept_body(path) == nil, "#{path} should not keep a raw body copy"
      end
    end
  end
end
