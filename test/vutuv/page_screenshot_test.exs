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
