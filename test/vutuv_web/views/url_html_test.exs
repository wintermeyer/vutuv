defmodule VutuvWeb.UrlHTMLTest do
  @moduledoc """
  `linkable_url/1` is the render chokepoint for stored profile-link URLs. It
  must never emit a non-http(s) href — a `javascript:`/`data:` scheme would
  execute on click on the public profile (stored XSS), so any such value
  (legacy or bypassed) renders as an inert "#".
  """
  use ExUnit.Case, async: true

  alias VutuvWeb.UrlHTML

  test "passes http(s) URLs through unchanged" do
    assert UrlHTML.linkable_url("https://example.org/x") == "https://example.org/x"
    assert UrlHTML.linkable_url("http://example.org") == "http://example.org"
  end

  test "prepends http:// to a schemeless value" do
    assert UrlHTML.linkable_url("example.org/path") == "http://example.org/path"
  end

  test "neutralizes javascript:/data:/other schemes to an inert href" do
    assert UrlHTML.linkable_url("javascript:alert(1)") == "#"
    assert UrlHTML.linkable_url("javascript://example.com/%0aalert(1)//http://x") == "#"
    assert UrlHTML.linkable_url("data:text/html,<script>alert(1)</script>") == "#"
    assert UrlHTML.linkable_url("vbscript:msgbox(1)") == "#"
  end

  describe "display_url/1 — the compact visible label" do
    test "shows just the host, without the http(s):// scheme" do
      assert UrlHTML.display_url("https://example.org") == "example.org"
      assert UrlHTML.display_url("http://example.org") == "example.org"
      assert UrlHTML.display_url("example.org") == "example.org"
    end

    test "treats a bare / path as no path (no ellipsis)" do
      assert UrlHTML.display_url("https://example.org/") == "example.org"
    end

    test "appends an ellipsis when the URL carries a path, query or fragment" do
      assert UrlHTML.display_url("https://example.org/some/long/path") == "example.org…"
      assert UrlHTML.display_url("https://example.org?q=1") == "example.org…"
      assert UrlHTML.display_url("https://example.org/#section") == "example.org…"
      assert UrlHTML.display_url("example.org/path") == "example.org…"
    end

    test "keeps subdomains" do
      assert UrlHTML.display_url("https://blog.example.org") == "blog.example.org"
    end
  end
end
