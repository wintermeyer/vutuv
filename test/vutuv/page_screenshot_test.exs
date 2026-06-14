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
    end)

    :ok
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
end
