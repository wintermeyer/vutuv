defmodule Vutuv.Profiles.UrlTest do
  @moduledoc """
  Profile-link URL validation. A stored link is screenshotted server-side by
  headless Chromium, so an internal host would be a readable SSRF (the rendered
  thumbnail leaks the internal page back on the public profile). Those hosts
  must be rejected at the changeset, before any capture is scheduled.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.Profiles.Url

  defp valid?(value) do
    Url.changeset(%Url{}, %{"value" => value, "description" => "x"}).valid?
  end

  test "accepts ordinary public URLs" do
    assert valid?("https://example.org/profile")
    assert valid?("example.org")
    assert valid?("http://sub.domain.co.uk/path?q=1")
  end

  test "prefixes a schemeless URL even when its query mentions http(s)://" do
    # The old substring guard skipped the prefix here, so validate_url then
    # rejected the (now scheme-less) value. It must be accepted and completed.
    changeset =
      Url.changeset(%Url{}, %{"value" => "example.com/r?to=https://other.example", "description" => "x"})

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :value) ==
             "http://example.com/r?to=https://other.example"
  end

  test "accepts a schemeless host:port URL (URI.parse misreads it as a scheme)" do
    # URI.parse("example.com:8080") yields scheme "example.com", so a nil-scheme
    # check would leave it un-prefixed and validate_url would reject it.
    changeset = Url.changeset(%Url{}, %{"value" => "example.com:8080/path", "description" => "x"})

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :value) == "http://example.com:8080/path"
  end

  test "rejects localhost and loopback hosts" do
    refute valid?("http://localhost/")
    refute valid?("http://localhost:4000/admin")
    refute valid?("http://127.0.0.1/")
    refute valid?("http://[::1]/")
  end

  test "rejects the cloud metadata address and private ranges" do
    refute valid?("http://169.254.169.254/latest/meta-data/")
    refute valid?("http://10.0.0.5/")
    refute valid?("http://192.168.1.1/")
    refute valid?("http://172.16.0.1/")
    refute valid?("http://0.0.0.0/")
  end

  test "rejects IPv4-mapped IPv6 and unique/link-local IPv6" do
    refute valid?("http://[::ffff:127.0.0.1]/")
    refute valid?("http://[fd00::1]/")
    refute valid?("http://[fe80::1]/")
  end

  test "still rejects single-label garbage hosts" do
    refute valid?("invalid_url")
  end

  test "rejects non-http(s) schemes that would become an executable href (XSS)" do
    refute valid?("javascript:alert(1)")
    # ensure_http_prefix skips prefixing because the value contains "http://",
    # so the real scheme reaches validation — it must still be rejected.
    refute valid?("javascript://example.com/%0aalert(document.cookie)//http://x.com")
    refute valid?("data:text/html;base64,PHNjcmlwdD4=//http://x.com")
    refute valid?("vbscript:msgbox(1)//http://x.com")
  end
end
