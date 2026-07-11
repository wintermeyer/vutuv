defmodule Vutuv.WebVerificationTest do
  @moduledoc """
  The shared web-proof primitives (DNS TXT, well-known file, rel=me back-link).
  The DNS resolver and the `Req` adapter are passed in explicitly, so these are
  pure unit tests that never touch real DNS or the network.
  """
  use ExUnit.Case, async: true

  alias Vutuv.WebVerification

  describe "gen_token/0 + dns_txt_value/2" do
    test "mints a URL-safe token and prefixes it for the TXT record" do
      token = WebVerification.gen_token()
      assert token =~ ~r/\A[A-Za-z0-9_-]+\z/

      # The prefix is caller-supplied: personal links and companies use their
      # own scheme, so a proof for one never doubles as a proof for the other.
      assert WebVerification.dns_txt_value("vutuv-verify=", token) == "vutuv-verify=" <> token

      assert WebVerification.dns_txt_value("vutuv-company-verify=", token) ==
               "vutuv-company-verify=" <> token
    end
  end

  describe "dns_verified?/4" do
    test "true only when the resolver returns a record with the given prefix" do
      token = "abc123"
      resolver = fn _host -> [[~c"vutuv-company-verify=#{token}"]] end

      assert WebVerification.dns_verified?(
               "example.org",
               "vutuv-company-verify=",
               token,
               resolver
             )

      # The personal-link prefix must not match a company record (and vice versa).
      refute WebVerification.dns_verified?("example.org", "vutuv-verify=", token, resolver)
    end

    test "false when the record is absent, and never raises on a resolver error" do
      refute WebVerification.dns_verified?("example.org", "vutuv-verify=", "abc123", fn _ ->
               []
             end)

      refute WebVerification.dns_verified?("example.org", "vutuv-verify=", "abc123", fn _ ->
               raise "boom"
             end)
    end
  end

  describe "well_known_verified?/4" do
    test "true when the file at the given path serves exactly the token (trimmed)" do
      opts = adapter(200, "  tok-123\n")
      path = "/.well-known/vutuv-verify.txt"
      assert WebVerification.well_known_verified?("example.org", path, "tok-123", opts)
    end

    test "false on a mismatch or a non-200" do
      path = "/.well-known/vutuv-company-verify.txt"

      refute WebVerification.well_known_verified?(
               "example.org",
               path,
               "tok-123",
               adapter(200, "nope")
             )

      refute WebVerification.well_known_verified?(
               "example.org",
               path,
               "tok-123",
               adapter(404, "")
             )
    end

    test "the fetched URL is the https host + the caller-supplied well-known path" do
      assert WebVerification.well_known_url("example.org", "/.well-known/vutuv-verify.txt") ==
               "https://example.org/.well-known/vutuv-verify.txt"

      assert WebVerification.well_known_url(
               "example.org",
               "/.well-known/vutuv-company-verify.txt"
             ) ==
               "https://example.org/.well-known/vutuv-company-verify.txt"
    end
  end

  describe "rel_me_hrefs/1 (the parser)" do
    test "finds rel=me hrefs on <a> and <link>, any attribute order, any quotes" do
      html = """
      <a href="https://vutuv.de/alice" rel="me">me</a>
      <link rel="me" href='https://other.example/alice'>
      <a rel="me noopener" href=https://third.example/alice>third</a>
      """

      hrefs = WebVerification.rel_me_hrefs(html)

      assert "https://vutuv.de/alice" in hrefs
      assert "https://other.example/alice" in hrefs
      assert "https://third.example/alice" in hrefs
    end

    test "ignores links whose rel does not contain the me token" do
      html = ~s(<a href="https://vutuv.de/alice" rel="nofollow">x</a><a href="https://x/y">y</a>)
      assert WebVerification.rel_me_hrefs(html) == []
    end

    test "does not treat 'me' as a substring of another rel token" do
      html = ~s(<a href="https://vutuv.de/alice" rel="metoo">x</a>)
      assert WebVerification.rel_me_hrefs(html) == []
    end
  end

  describe "normalize_url/1" do
    test "is scheme / www / trailing-slash insensitive" do
      assert WebVerification.normalize_url("https://www.vutuv.de/alice/") ==
               WebVerification.normalize_url("http://vutuv.de/alice")
    end

    test "a relative path never matches an absolute expected URL" do
      refute WebVerification.normalize_url("/alice") ==
               WebVerification.normalize_url("https://vutuv.de/alice")
    end
  end

  describe "rel_me_verified?/3" do
    test "true when the page links back to an expected profile URL" do
      body = ~s(<html><head><link rel="me" href="https://vutuv.de/alice"></head></html>)
      opts = adapter(200, body)

      assert WebVerification.rel_me_verified?(
               "https://alice.example/",
               ["https://www.vutuv.de/alice"],
               opts
             )
    end

    test "false when the back-link points somewhere else" do
      body = ~s(<a rel="me" href="https://vutuv.de/bob">bob</a>)

      refute WebVerification.rel_me_verified?(
               "https://alice.example/",
               ["https://vutuv.de/alice"],
               adapter(200, body)
             )
    end

    test "false on a non-200 or an unreachable host" do
      refute WebVerification.rel_me_verified?(
               "https://alice.example/",
               ["https://vutuv.de/alice"],
               adapter(404, "")
             )
    end
  end

  # A Req adapter that answers every request with the given status + body.
  defp adapter(status, body) do
    [adapter: fn req -> {req, %Req.Response{status: status, body: body}} end]
  end
end
