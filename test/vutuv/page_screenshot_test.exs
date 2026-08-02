defmodule Vutuv.PageScreenshotTest do
  @moduledoc """
  capture/2 shells out to Chromium and must never raise, even when the binary
  is missing or the page hangs. A capture that crashed the caller would leave
  the broken flag unset and (historically) orphaned Chromium processes behind.
  The profile path also refuses URLs that resolve to an internal address before
  ever launching Chromium (DNS rebinding, issue #777).
  """
  # Not async: these tests set the global `:chromium_path` / `:ssrf_resolver` env.
  use Vutuv.DataCase, async: false

  import ExUnit.CaptureLog
  import Vutuv.Factory

  alias Vutuv.SocialFeed.Http

  setup do
    prev = Application.get_env(:vutuv, :chromium_path)
    prev_resolver = Application.get_env(:vutuv, :ssrf_resolver)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:vutuv, :chromium_path, prev),
        else: Application.delete_env(:vutuv, :chromium_path)

      Application.put_env(:vutuv, :ssrf_resolver, prev_resolver)
      Application.delete_env(:vutuv, :page_screenshot_probe_req_options)
    end)

    :ok
  end

  # Stub the redirect-resolution probe with a Req `plug` responder, so the
  # profile path's preflight never touches the network in a test.
  defp stub_probe(fun) do
    Application.put_env(:vutuv, :page_screenshot_probe_req_options, plug: fun)
  end

  # A stand-in "Chromium" that records its argv (one element per line, so the
  # space-carrying `--host-resolver-rules=MAP * ~NOTFOUND,...` stays one line)
  # and writes no screenshot. Lets a test assert the exact command line without
  # a browser.
  defp fake_chromium(args_file) do
    path = Path.join(System.tmp_dir!(), "fake-chromium-#{System.unique_integer([:positive])}")
    File.write!(path, "#!/bin/sh\nprintf '%s\\n' \"$@\" > #{args_file}\n")
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "these are capture policy only, not what to shoot or how to talk to it" do
    args = Vutuv.PageScreenshot.capture_args()

    # Nothing here tells the browser what to shoot or where to put it any more:
    # `Vutuv.PageScreenshot.Cdp` navigates and captures over the protocol, and
    # owns the flag that opens that channel along with the rest of its plumbing.
    refute Enum.any?(args, &String.starts_with?(&1, "--screenshot"))
    refute Enum.any?(args, &String.starts_with?(&1, "--timeout"))
    refute Enum.any?(args, &String.starts_with?(&1, "--remote-debugging"))
    refute Enum.any?(args, &String.starts_with?(&1, "http"))
  end

  test "the capture browser identifies itself with vutuv's own user agent" do
    args = Vutuv.PageScreenshot.capture_args()

    # Same string the HTTP preflight probes with, so a site sees one agent for
    # both requests instead of a nameless Chrome for the shot. Our own pages
    # read it too: the post permalink drops its arrival auto-scroll for it,
    # because the capture renders the document from the top and a page that
    # scrolls itself is shot before those tiles are painted — the empty
    # preview image of issue #1033.
    assert "--user-agent=#{Http.user_agent()}" in args
  end

  describe "capture_args/1 proxy egress (SSRF control)" do
    test "no proxy port means no proxy and no resolver flags (EvidenceScreenshot's own-host path)" do
      args = Vutuv.PageScreenshot.capture_args()
      refute Enum.any?(args, &String.starts_with?(&1, "--proxy-server"))
      refute Enum.any?(args, &String.starts_with?(&1, "--host-resolver-rules"))
    end

    test "a proxy port routes every connection through the loopback SOCKS proxy, DNS included" do
      args = Vutuv.PageScreenshot.capture_args(proxy_port: 1080)

      # Chromium treats `socks5://` as remote-DNS: it sends the proxy each
      # hostname in CONNECT instead of resolving it locally, which is what
      # lets the proxy vet every connection (seed, subresources, redirects).
      assert "--proxy-server=socks5://127.0.0.1:1080" in args

      # Belt and braces from Chromium's own SOCKS recipe: any name resolution
      # that would happen OUTSIDE the proxy fails (`~NOTFOUND`), so nothing
      # can slip past the vetting — fail closed, per the safety-check rule.
      assert "--host-resolver-rules=MAP * ~NOTFOUND,EXCLUDE 127.0.0.1" in args
    end
  end

  test "capture_framed routes Chromium through the vetting SOCKS proxy" do
    # A public-looking host that resolves publicly: capture_framed must launch
    # Chromium with ALL egress forced through the loopback SOCKS proxy, which
    # re-vets every connection's hostname right before dialling it. (The old
    # `MAP * <vetted-ip>` pin also sent every SUBRESOURCE host to the seed's
    # IP, which broke CSS/JS on any site serving assets from a CDN domain —
    # GitHub pages screenshotted as bare unstyled HTML.)
    Application.put_env(:vutuv, :ssrf_resolver, fn _host, _family ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    args_file =
      Path.join(System.tmp_dir!(), "chromium-args-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(args_file) end)
    Application.put_env(:vutuv, :chromium_path, fake_chromium(args_file))

    # The fake binary records argv and writes no image, so framing fails and
    # capture_framed returns an error — but the recorded args are what we assert.
    _ = Vutuv.PageScreenshot.capture_framed("https://public.example/page", "cap1")

    recorded = File.read!(args_file)
    assert recorded =~ "--proxy-server=socks5://127.0.0.1:"
    assert recorded =~ "--host-resolver-rules=MAP * ~NOTFOUND,EXCLUDE 127.0.0.1"
  end

  test "capture_framed fails closed when the vetting proxy is down: no unprotected Chromium" do
    # Without the proxy Chromium would fall back to its own DNS and egress,
    # reopening the SSRF hole — so a missing proxy must abort the capture
    # entirely (as a transient environment failure), never degrade to an
    # unvetted run.
    :ok = Supervisor.terminate_child(Vutuv.Supervisor, Vutuv.Ssrf.SocksProxy)
    on_exit(fn -> Supervisor.restart_child(Vutuv.Supervisor, Vutuv.Ssrf.SocksProxy) end)

    Application.put_env(:vutuv, :ssrf_resolver, fn _host, _family ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    args_file =
      Path.join(System.tmp_dir!(), "chromium-args-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(args_file) end)
    Application.put_env(:vutuv, :chromium_path, fake_chromium(args_file))

    assert {:error, :proxy_unavailable} =
             Vutuv.PageScreenshot.capture_framed("https://public.example/page", "cap4")

    # Chromium was never spawned — the whole point of failing closed.
    refute File.exists?(args_file)
  end

  test "capture_framed refuses a blocklisted page before resolving or launching Chromium" do
    args_file =
      Path.join(System.tmp_dir!(), "chromium-args-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(args_file) end)
    Application.put_env(:vutuv, :chromium_path, fake_chromium(args_file))

    # The seeded blocklist ships reddit.com (see Vutuv.ScreenshotBlocklist).
    assert {:error, :blocklisted} =
             Vutuv.PageScreenshot.capture_framed("https://reddit.com/r/elixir", "cap3")

    # No DNS resolve, no Chromium spawn — the whole point is spending nothing.
    refute File.exists?(args_file)
  end

  describe "generate_screenshot/1 on a blocklisted link" do
    setup do
      user = insert_activated_user()
      %{url: insert(:url, user: user, value: "https://www.heise.de/newsticker/meldung-1.html")}
    end

    test "stores nothing and does not flag the link as broken", %{url: url} do
      # A page we deliberately never capture is not a failure: flagging it would
      # poison a perfectly good link, and the bulk task would then skip it for
      # the wrong reason.
      assert :ok = Vutuv.PageScreenshot.generate_screenshot(url)

      reloaded = Vutuv.Repo.get!(Vutuv.Profiles.Url, url.id)
      assert is_nil(reloaded.screenshot)
      assert is_nil(reloaded.broken?)
    end
  end

  test "purge_blocklisted/0 drops the screenshots taken before an entry existed" do
    user = insert_activated_user()

    blocked =
      insert(:url, user: user, value: "https://www.heise.de/x", screenshot: "a1b2c3d4e5f6.webp")

    kept =
      insert(:url, user: user, value: "https://example.com/x", screenshot: "b0efec47a6e9.webp")

    assert Vutuv.PageScreenshot.purge_blocklisted() == 1

    assert is_nil(Vutuv.Repo.get!(Vutuv.Profiles.Url, blocked.id).screenshot)
    assert Vutuv.Repo.get!(Vutuv.Profiles.Url, kept.id).screenshot == "b0efec47a6e9.webp"
  end

  test "capture_framed refuses a host that resolves to an internal IP before launching Chromium" do
    Application.put_env(:vutuv, :ssrf_resolver, fn _host, _family -> {:ok, [{10, 0, 0, 5}]} end)

    args_file =
      Path.join(System.tmp_dir!(), "chromium-args-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(args_file) end)
    Application.put_env(:vutuv, :chromium_path, fake_chromium(args_file))

    assert {:error, :internal_target} =
             Vutuv.PageScreenshot.capture_framed("https://rebind.example/page", "cap2")

    # Chromium was never spawned, so no argv was recorded.
    refute File.exists?(args_file)
  end

  test "returns an error tuple (never raises) when the configured binary is missing" do
    Application.put_env(:vutuv, :chromium_path, "/nonexistent/definitely-not-chromium")
    out = Path.join(System.tmp_dir!(), "ps_#{System.unique_integer([:positive])}.png")

    assert {:error, _reason} = Vutuv.PageScreenshot.capture("https://example.com", out)
    refute File.exists?(out)
  end

  test "refuses a profile URL whose host resolves to an internal address (DNS rebinding)" do
    user = insert(:user)
    url = insert(:url, user: user, value: "https://rebind.attacker.example/page", broken?: false)

    # Resolve the public-looking host to an internal IP; the guard must fire
    # before Chromium is launched. `:internal_target` in the log distinguishes
    # the SSRF refusal from a missing-binary failure.
    Application.put_env(:vutuv, :ssrf_resolver, fn _host, _family -> {:ok, [{10, 0, 0, 5}]} end)

    log =
      capture_log(fn ->
        assert :error = Vutuv.PageScreenshot.generate_screenshot(url)
      end)

    assert log =~ "internal_target"
    assert Repo.get!(Vutuv.Profiles.Url, url.id).broken? == true
  end

  test "refuses a profile URL that 3xx-redirects to an internal address" do
    user = insert(:user)
    url = insert(:url, user: user, value: "https://public.example/page", broken?: false)

    # The public-looking host resolves publicly and answers 200-less: it 302s to
    # the cloud-metadata address. Chromium would follow that and screenshot the
    # internal page into the member's public profile image; the per-hop guard
    # must refuse it before Chromium is ever launched.
    Application.put_env(:vutuv, :ssrf_resolver, fn _host, _family ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    stub_probe(fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "http://169.254.169.254/latest/meta-data/")
      |> Plug.Conn.resp(302, "")
    end)

    log =
      capture_log(fn ->
        assert :error = Vutuv.PageScreenshot.generate_screenshot(url)
      end)

    assert log =~ "internal_target"
    assert Repo.get!(Vutuv.Profiles.Url, url.id).broken? == true
  end

  test "an environment failure is logged but does not poison the URL, so it is retried later" do
    user = insert(:user)
    url = insert(:url, user: user, value: "https://example.com/page", broken?: false)

    # A public host (so the SSRF guard passes) but no usable Chromium: the
    # capture fails for an *environmental* reason, not because the URL is bad.
    # Issue #906 was exactly this — a Chromium package upgrade that crashed
    # headless capture, silently flagging every fresh link `broken?` so it was
    # never retried even after the environment recovered.
    Application.put_env(:vutuv, :ssrf_resolver, fn _host, _family ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    stub_probe(fn conn -> Plug.Conn.resp(conn, 200, "ok") end)
    Application.put_env(:vutuv, :chromium_path, "/nonexistent/definitely-not-chromium")

    log =
      capture_log(fn ->
        assert :error = Vutuv.PageScreenshot.generate_screenshot(url)
      end)

    # Logged at :error so a broken capture pipeline is visible under prod's
    # :error Logger level, instead of failing silently ...
    assert log =~ "screenshot generation failed"
    # ... and the row is left un-poisoned, so the bulk urls.create_screenshots
    # task retries it once capture works again.
    refute Repo.get!(Vutuv.Profiles.Url, url.id).broken?
  end
end
