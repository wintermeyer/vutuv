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

      # The prefix is caller-supplied: personal links and organizations use their
      # own scheme, so a proof for one never doubles as a proof for the other.
      assert WebVerification.dns_txt_value("vutuv-verify=", token) == "vutuv-verify=" <> token

      assert WebVerification.dns_txt_value("vutuv-organization-verify=", token) ==
               "vutuv-organization-verify=" <> token
    end
  end

  describe "dns_verified?/4" do
    test "true only when the resolver returns a record with the given prefix" do
      token = "abc123"
      resolver = fn _host -> [[~c"vutuv-organization-verify=#{token}"]] end

      assert WebVerification.dns_verified?(
               "example.org",
               "vutuv-organization-verify=",
               token,
               resolver
             )

      # The personal-link prefix must not match an organization record (and vice versa).
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

    test "also accepts the record at the CNAME-safe _vutuv.<host> alternate name" do
      token = "abc123"
      expected = ~c"vutuv-verify=#{token}"

      # A host that is itself a CNAME (a hosted page, a redirect) cannot carry a
      # bare-host TXT record — a CNAME and a TXT cannot coexist on one name
      # (RFC 1034). The member publishes the record at `_vutuv.<host>` instead,
      # a name that is never a CNAME target, and it must still verify.
      resolver = fn
        "_vutuv.changelog.example.org" -> [[expected]]
        _ -> []
      end

      assert WebVerification.dns_verified?(
               "changelog.example.org",
               "vutuv-verify=",
               token,
               resolver
             )
    end

    test "dns_challenge_name/1 prefixes the host with the _vutuv label" do
      assert WebVerification.dns_challenge_name("changelog.example.org") ==
               "_vutuv.changelog.example.org"
    end
  end

  describe "well_known_verified?/4" do
    test "true when the file at the given path serves exactly the token (trimmed)" do
      opts = adapter(200, "  tok-123\n")
      path = "/.well-known/vutuv-verify.txt"
      assert WebVerification.well_known_verified?("example.org", path, "tok-123", opts)
    end

    test "false on a mismatch or a non-200" do
      path = "/.well-known/vutuv-organization-verify.txt"

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
               "/.well-known/vutuv-organization-verify.txt"
             ) ==
               "https://example.org/.well-known/vutuv-organization-verify.txt"
    end
  end

  describe "check reports (issue #1466)" do
    test "the dns report names both queried names and every record it saw" do
      resolver = fn _host -> [[~c"v=spf1 -all"], [~c"other=1"]] end

      assert {:error, report} =
               WebVerification.dns_check(
                 "example.org",
                 "vutuv-organization-verify=",
                 "tok-123",
                 resolver
               )

      assert report.method == "dns"
      assert report.names == ["example.org", "_vutuv.example.org"]
      assert report.expected == "vutuv-organization-verify=tok-123"
      assert report.found == ["v=spf1 -all", "other=1"]
    end

    test "a hit on the bare host stops there, so the happy path stays one lookup" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      resolver = fn host ->
        Agent.update(agent, &[host | &1])
        [[~c"vutuv-organization-verify=tok-123"]]
      end

      assert {:ok, _report} =
               WebVerification.dns_check(
                 "example.org",
                 "vutuv-organization-verify=",
                 "tok-123",
                 resolver
               )

      assert Agent.get(agent, & &1) == ["example.org"]
    end

    test "the well-known report separates a wrong body, a bad status and no answer at all" do
      path = "/.well-known/vutuv-organization-verify.txt"

      assert {:error, served} =
               WebVerification.well_known_check(
                 "example.org",
                 path,
                 "tok-123",
                 adapter(200, "no")
               )

      assert served.status == 200
      assert served.found == "no"
      assert served.url == "https://example.org" <> path

      assert {:error, missing} =
               WebVerification.well_known_check("example.org", path, "tok-123", adapter(404, ""))

      assert missing.status == 404

      # No response at all — here because the SSRF guard refused to leave the
      # machine, the same shape a DNS or TLS failure produces.
      assert {:error, unreachable} =
               WebVerification.well_known_check("localhost", path, "tok-123", adapter(200, "tok"))

      assert is_nil(unreachable.status)
    end

    test "an answer with control characters is cut down to one printable line" do
      path = "/.well-known/vutuv-organization-verify.txt"
      body = "line one\nline two\r\n" <> String.duplicate("x", 400)

      assert {:error, report} =
               WebVerification.well_known_check("example.org", path, "tok", adapter(200, body))

      refute report.found =~ "\n"
      assert String.length(report.found) <= 160
    end

    test "the rel=me report lists the back-links the page actually has" do
      body = ~s(<a rel="me" href="https://github.com/alice">gh</a><a href="/about">about</a>)

      assert {:error, report} =
               WebVerification.rel_me_check(
                 "https://alice.example/",
                 ["https://vutuv.de/alice"],
                 adapter(200, body)
               )

      assert report.method == "rel_me"
      assert report.url == "https://alice.example/"
      assert report.status == 200
      assert report.expected == ["https://vutuv.de/alice"]
      # The rel=me link it does have — the whole diagnosis when a member marked
      # the wrong one of several profile links, or none at all.
      assert report.found == ["https://github.com/alice"]
    end

    test "the rel=me report separates a bad status from a page with no back-link" do
      assert {:error, missing} =
               WebVerification.rel_me_check(
                 "https://alice.example/",
                 ["https://vutuv.de/alice"],
                 adapter(404, "")
               )

      assert missing.status == 404
      assert missing.found == []

      assert {:error, unreachable} =
               WebVerification.rel_me_check(
                 "http://localhost/",
                 ["https://vutuv.de/alice"],
                 adapter(200, ~s(<a rel="me" href="https://vutuv.de/alice">x</a>))
               )

      assert is_nil(unreachable.status)
    end

    test "rel_me_verified?/3 is the same check, so the two can never disagree" do
      body = ~s(<link rel="me" href="https://vutuv.de/alice">)
      opts = adapter(200, body)

      assert {:ok, _report} =
               WebVerification.rel_me_check(
                 "https://alice.example/",
                 ["https://vutuv.de/alice"],
                 opts
               )

      assert WebVerification.rel_me_verified?(
               "https://alice.example/",
               ["https://vutuv.de/alice"],
               opts
             )
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
