defmodule Vutuv.PageScreenshot do
  @moduledoc """
  Generates the screenshot for a profile URL.

  Replaces the former BrowserStack integration with a local headless Chromium
  capture: render the page, wrap it in a browser window frame
  (`Vutuv.BrowserFrame`), then store it through the `Url` changeset (which
  writes the original plus a thumb via `Vutuv.Screenshot`).

  The Chromium binary is located from, in order: the `:vutuv, :chromium_path`
  application env, the `CHROMIUM_PATH` environment variable, the usual binaries
  on `$PATH`, and finally the macOS app bundle (handy for local development).
  Window size defaults to 1280x800 and is configurable via
  `:vutuv, :screenshot_window_size`.
  """

  require Logger

  alias Vutuv.BrowserFrame
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Profiles.Url
  alias Vutuv.Repo
  alias Vutuv.SocialFeed.Http
  alias Vutuv.Ssrf
  alias Vutuv.Ssrf.SocksProxy

  @candidate_binaries ~w(chromium chromium-browser google-chrome google-chrome-stable chrome)
  @macos_paths [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium"
  ]
  @default_window {1280, 800}
  # Redirect hops we follow while resolving a member link to its final public
  # URL (enough for the common http->https + apex->www chains).
  @max_redirect_hops 5
  # Test seam: options merged into the redirect-resolution probe (a Req `plug`
  # stub in tests). Empty in prod. An atom key (like the post path's) — a tuple
  # key is deprecated in Elixir 1.20.
  @probe_req_options_key :page_screenshot_probe_req_options
  # Hard ceiling for one Chromium run. `timeout` enforces it at the OS level
  # (and kills Chromium, so it can't be orphaned); the BEAM-side Task adds a
  # slightly looser backstop.
  @capture_seconds 30
  @capture_grace 5
  # Chromium's own stop, comfortably inside the OS ceiling above. Headless
  # Chromium takes the shot when the page finishes loading, and a page whose
  # network never goes quiet never gets there: `--screenshot` then blocks until
  # the OS kills it and we store nothing at all. `--timeout` stops the load and
  # shoots what is rendered instead.
  @page_timeout_seconds 20

  @doc """
  Capture `url`'s screenshot off the request path, fire-and-forget: supervised
  under `Vutuv.TaskSupervisor` (so it survives a mid-request node restart rather
  than being a dropped `Task.start`) and gated by `:generate_screenshots` (tests
  launch no headless Chromium and never touch the SQL Sandbox from an unrelated
  process). Shared by the HTML link forms and the API's link writes.
  """
  def generate_async(%Url{} = url) do
    if Application.get_env(:vutuv, :generate_screenshots, true) do
      Task.Supervisor.start_child(Vutuv.TaskSupervisor, fn -> generate_screenshot(url) end)
    end

    :ok
  end

  @doc """
  Renders, frames, and stores the screenshot for `url`.

  On success the URL is marked `broken?: false`. On failure the two kinds of
  failure are kept apart:

    * a genuinely un-capturable *target* — an SSRF-refused internal host
      (issue #777) — is a permanent property of the URL, so it is marked
      `broken?: true` and the bulk `urls.create_screenshots` task skips it;

    * an *environment* failure — Chromium missing, crashed or timed out (issue
      #906 was a bad Chromium package upgrade that crashed headless capture) —
      is transient and hits every URL alike, so the row is **not** poisoned
      (leaving it for the bulk task to retry once capture works again) and it is
      logged at `:error` so a broken pipeline is visible under prod's `:error`
      Logger level rather than failing silently.

  Safe to run from an unsupervised `Task` — all failures are logged, never
  raised.
  """
  def generate_screenshot(%Url{id: id}) do
    case Repo.get(Url, id) do
      nil -> :ok
      url -> capture_store_and_flag(url)
    end
  end

  defp capture_store_and_flag(url) do
    case capture_and_frame(url) do
      {:ok, framed_path} ->
        store(url, framed_path)
        set_broken(url, false)
        File.rm(framed_path)
        :ok

      {:error, reason} when reason in [:internal_target, :blocked_host] ->
        # A permanent property of this URL and an expected policy outcome — an
        # SSRF-refused internal host (issue #777) or a blocklisted host that
        # never screenshots (a login/consent wall). Flag it so the bulk task
        # never retries it, and log quietly.
        Logger.warning(failure_message(url, reason))
        set_broken(url, true)
        :error

      {:error, reason} ->
        # An environment failure (Chromium missing, crashed or timed out): it
        # affects every URL alike (issue #906), so don't poison the row — leave
        # `broken?` untouched for the bulk task to retry — and log at :error so
        # a broken capture pipeline surfaces under prod's :error Logger level.
        Logger.error(failure_message(url, reason))
        :error
    end
  end

  defp failure_message(url, reason) do
    "screenshot generation failed for url ##{url.id} (#{url.value}): #{inspect(reason)}"
  end

  # The profile path's own preflight (the post path has its own, ensure_http_ok):
  # resolve the member link's redirect chain, validating every hop, so Chromium
  # only ever receives a public URL. Frames the resolved target.
  defp capture_and_frame(url) do
    with {:ok, target} <- resolve_public_target(url.value) do
      capture_framed(target, url.id)
    end
  end

  @doc """
  Captures `url_value`, wraps it in a browser-window frame, and returns
  `{:ok, framed_webp_path}` (the caller stores it and must `File.rm/1` it) or
  `{:error, reason}`. `id` only names the temp files. Never raises.

  Shared by the profile-link path (`Url`) and the post link-screenshot queue
  (`Vutuv.Posts.Screenshots`), so the SSRF guard and the capture→frame pipeline
  live in exactly one place.

  `url_value` is an untrusted member-supplied link. The changeset already
  rejected literal internal hosts, but a public hostname can resolve to an
  internal IP (DNS rebinding, issue #777), so resolve at capture time and refuse
  before handing the URL to Chromium.

  The resolve here only *classifies* the seed URL — a host resolving solely to
  internal addresses is a permanent property of the URL (`:internal_target`,
  never retried); one that does not resolve at all right now is transient
  (`:unresolvable_target`, the caller retries). The actual SSRF egress control
  is `Vutuv.Ssrf.SocksProxy`: Chromium is launched with **all** connections
  forced through that loopback SOCKS5 proxy (see `capture_args/3`), which
  re-resolves and vets every target — the seed page, each subresource host, any
  redirect / `<meta refresh>` / JS-navigation destination, and IP literals —
  right before dialling it, and refuses internal ones. That closes the
  SSRF-via-capture hole of GHSA-mmjf-8cwc-6vwv (CWE-918) without the collateral
  of the earlier `MAP * <vetted-ip>` DNS pin, which sent every subresource host
  to the seed's IP and so broke CSS/JS on any site serving assets from a CDN
  domain (GitHub screenshotted as bare unstyled HTML). If the proxy is not
  running, the capture **fails closed** (`:proxy_unavailable`, transient) —
  Chromium is never launched unprotected.

  `Vutuv.Moderation.EvidenceScreenshot` calls `capture/3` directly to shoot the
  app's own host (which may legitimately be internal) and is intentionally
  neither gated nor proxied.
  """
  def capture_framed(url_value, id) when is_binary(url_value) do
    if host_blocked?(url_value) do
      {:error, :blocked_host}
    else
      capture_vetted(url_value, id)
    end
  end

  defp capture_vetted(url_value, id) do
    case Ssrf.vetted_address(URI.parse(url_value).host) do
      {:ok, _public_ip} ->
        capture_proxied(url_value, id)

      {:error, :internal} ->
        {:error, :internal_target}

      {:error, :unresolvable} ->
        {:error, :unresolvable_target}
    end
  end

  defp capture_proxied(url_value, id) do
    case SocksProxy.port() do
      {:ok, proxy_port} ->
        page_path = tmp_path("page", id, "png")
        framed_path = tmp_path("frame", id, "webp")

        try do
          with :ok <- capture(url_value, page_path, proxy_port: proxy_port),
               {:ok, ^framed_path} <- BrowserFrame.wrap(page_path, url_value, framed_path) do
            {:ok, framed_path}
          end
        after
          File.rm(page_path)
        end

      {:error, :not_running} ->
        # Fail closed: without the vetting proxy Chromium would do its own DNS
        # and egress and could be steered onto an internal host, so no capture
        # happens at all. An environment failure like a missing Chromium —
        # transient, logged at :error, the row is not poisoned.
        {:error, :proxy_unavailable}
    end
  end

  @doc """
  True when `url`'s host is on the screenshot blocklist
  (`:screenshot_blocked_hosts`, default `["reddit.com"]`, override via
  `SCREENSHOT_BLOCKED_HOSTS`). Those sites answer a headless capture with a
  login / consent wall or block bots outright, so the shot is never useful
  preview content — the caller skips the capture instead of spending a Chromium
  run on it. Matches the apex host and any subdomain (`old.reddit.com`), so one
  entry covers a site's mirrors.
  """
  def host_blocked?(url) when is_binary(url) do
    case URI.parse(url).host do
      nil -> false
      host -> host_on_blocklist?(String.downcase(host))
    end
  end

  def host_blocked?(_url), do: false

  defp host_on_blocklist?(host) do
    Enum.any?(blocked_hosts(), fn blocked ->
      host == blocked or String.ends_with?(host, "." <> blocked)
    end)
  end

  defp blocked_hosts do
    :vutuv
    |> Application.get_env(:screenshot_blocked_hosts, [])
    |> Enum.map(&String.downcase/1)
  end

  # Resolve a member link to the final PUBLIC URL Chromium should shoot,
  # following HTTP redirects but validating EVERY hop's host against the SSRF
  # guard. This closes the redirect bypass: a public host that 3xx-redirects to
  # 169.254.169.254 / a LAN address would otherwise be followed by Chromium and
  # screenshotted into the member's public profile image. A legit apex->www or
  # http->https redirect still resolves. Only a redirecting URL is probed; a
  # direct (or unreachable) URL is handed to Chromium unchanged, exactly as
  # before, so a 404 / down link keeps its old behaviour.
  defp resolve_public_target(url, hops \\ @max_redirect_hops) do
    cond do
      Ssrf.resolves_to_internal?(URI.parse(url).host) -> {:error, :internal_target}
      hops <= 0 -> {:error, :too_many_redirects}
      true -> follow_or_accept(url, hops)
    end
  end

  defp follow_or_accept(url, hops) do
    case probe(url) do
      {:ok, %Req.Response{status: status} = resp} when status in 300..399 ->
        case redirect_target(url, resp) do
          nil -> {:error, :bad_redirect}
          next -> resolve_public_target(next, hops - 1)
        end

      # A direct (non-redirect) or unreachable response: hand this URL to Chromium
      # unchanged, exactly as before.
      _direct_or_unreachable ->
        {:ok, url}
    end
  rescue
    # The module contract is "never raises"; a probe blowing up degrades to the
    # pre-existing behaviour of letting Chromium try the URL.
    _ -> {:ok, url}
  end

  defp redirect_target(from_url, resp) do
    case Req.Response.get_header(resp, "location") do
      [location | _] -> from_url |> URI.merge(location) |> URI.to_string()
      _ -> nil
    end
  end

  # We only read the status line and `location` header of the probe, never the
  # body, so drop it during receipt at a small ceiling: a hostile member link
  # could otherwise stream an unbounded body into memory (scan finding F15).
  @probe_max_body_bytes 64 * 1024

  # A `redirect: false` GET so we see (and validate) each 3xx hop ourselves.
  defp probe(url) do
    [
      url: url,
      receive_timeout: 5_000,
      connect_options: [timeout: 3_000],
      retry: false,
      redirect: false,
      # The body is never read, so Req must not spend work on (or fail over)
      # decoding it — a member link answering malformed `application/json`
      # would otherwise error the probe.
      decode_body: false,
      into: Vutuv.Http.capped_collector(@probe_max_body_bytes),
      headers: [{"user-agent", Http.user_agent()}]
    ]
    |> Keyword.merge(Application.get_env(:vutuv, @probe_req_options_key, []))
    |> Req.get()
  end

  defp store(url, framed_path) do
    upload = %Plug.Upload{
      content_type: "image/webp",
      filename: "#{url.id}.webp",
      path: framed_path
    }

    result =
      url
      |> Url.changeset(%{screenshot: upload})
      |> Repo.update()

    # The fresh capture waits in AI-moderation limbo until the scan releases
    # it (Vutuv.Moderation.ImageScans) — a screenshot of an NSFW page must
    # not reach the public link card.
    with {:ok, updated} <- result do
      ImageScans.enqueue("url_screenshot", updated.id, updated.user_id, updated.screenshot)
    end

    result
  end

  defp set_broken(url, value) do
    url
    |> Url.changeset(%{broken?: value})
    |> Repo.update()
  end

  @doc """
  Captures `url` to `out_path` as a PNG using headless Chromium.

  `opts` may carry `window: {width, height}` to override the configured
  window size (headless Chromium only shoots the viewport, so a full-page
  capture of a known-tall page is "very tall window, then trim" - see
  `Vutuv.Moderation.EvidenceScreenshot`).

  Returns `:ok` or `{:error, reason}`. Never raises.
  """
  def capture(url, out_path, opts \\ []) do
    case binary() do
      nil -> {:error, :chromium_not_found}
      bin -> run(bin, capture_args(url, out_path, opts), out_path)
    end
  end

  @doc """
  The Chromium command line `capture/3` runs. Split out so the flags are
  testable without a Chromium binary.

  `--timeout` is the one that decides whether a slow page yields anything:
  headless Chromium shoots when the page finishes loading, so a page whose
  network never goes quiet — GitHub's issue search is one — blocks
  `--screenshot` until the OS force-kill and stores **nothing**.
  `--virtual-time-budget` does *not* bound that under `--headless=new`, so it is
  no substitute; with `--timeout` the load is stopped and whatever has rendered
  is captured, which is what a member sees in their own browser anyway.

  `--user-agent` names the installation the same way the HTTP preflight probe
  does, so a site sees one agent for both requests instead of a nameless Chrome
  for the shot — and our own pages can recognise the capture
  (`Vutuv.SocialFeed.Http.own_agent?/1`) and skip on-arrival behaviour that
  would spoil it: `--screenshot` renders the document **from the top**, so a
  page that scrolls itself on arrival is captured before those tiles are
  painted and stores a blank image (issue #1033).

  `opts[:proxy_port]` routes **all** of Chromium's egress through the loopback
  SOCKS5 vetting proxy (`Vutuv.Ssrf.SocksProxy`) on that port — the SSRF egress
  control (GHSA-mmjf-8cwc-6vwv). Two flags, both needed:

    * `--proxy-server=socks5://127.0.0.1:<port>` — Chromium treats `socks5://`
      as remote-DNS (its network-stack docs): it resolves no hostname itself
      but sends each one to the proxy in the CONNECT request, so the proxy can
      resolve-and-vet every connection (seed page, subresources, redirect /
      meta-refresh / JS-navigation targets, IP literals) right before dialling.
    * `--host-resolver-rules=MAP * ~NOTFOUND,EXCLUDE 127.0.0.1` — Chromium's
      own documented companion recipe: any name resolution attempted *outside*
      the proxy fails, so nothing can slip past the vetting (fail closed).

  This replaced pinning every name to the seed's vetted IP (`MAP * <ip>`),
  which was equally safe but sent every *subresource* host to the seed's
  address: on any site serving CSS/JS from a CDN domain those fetches died on
  a certificate mismatch, and e.g. GitHub pages screenshotted as bare
  unstyled HTML. Omitted (`EvidenceScreenshot` shooting our own, possibly
  internal, host), no proxy flags are added and Chromium runs direct.
  """
  def capture_args(url, out_path, opts \\ []) do
    {width, height} = Keyword.get(opts, :window, window_size())

    # `--headless=new` already runs in a fresh throwaway profile per
    # invocation, so concurrent captures don't clash and nothing is left
    # behind in $HOME. `--disable-dev-shm-usage` avoids the small default
    # /dev/shm crashing Chromium on minimal server setups.
    [
      "--headless=new",
      "--disable-gpu",
      "--hide-scrollbars",
      "--no-sandbox",
      "--disable-dev-shm-usage",
      "--no-first-run",
      "--disable-extensions",
      "--force-device-scale-factor=1",
      "--virtual-time-budget=8000",
      "--timeout=#{@page_timeout_seconds * 1000}",
      "--user-agent=#{Http.user_agent()}",
      "--window-size=#{width},#{height}",
      "--screenshot=#{out_path}"
    ] ++ proxy_args(Keyword.get(opts, :proxy_port)) ++ [url]
  end

  defp proxy_args(nil), do: []

  defp proxy_args(proxy_port) do
    [
      "--proxy-server=socks5://127.0.0.1:#{proxy_port}",
      "--host-resolver-rules=MAP * ~NOTFOUND,EXCLUDE 127.0.0.1"
    ]
  end

  @doc "The OS-level ceiling for one Chromium run, in seconds."
  def capture_seconds, do: @capture_seconds

  # Chromium can hang on hostile or dead pages. Wrap it in `timeout` so the
  # OS force-kills the process (its children follow) instead of leaving an
  # orphaned Chromium behind when the BEAM-side Task is shut down.
  defp run(bin, args, out_path) do
    {cmd, cmd_args} = wrap_timeout(bin, args)
    task = Task.async(fn -> safe_cmd(cmd, cmd_args) end)

    result =
      case Task.yield(task, (@capture_seconds + @capture_grace + 5) * 1000) || Task.shutdown(task) do
        {:ok, {:ok, {_output, 0}}} ->
          :ok

        {:ok, {:ok, {output, code}}} ->
          {:error, {:exit_status, code, String.slice(output, 0, 500)}}

        {:ok, {:error, reason}} ->
          {:error, reason}

        _ ->
          {:error, :timeout}
      end

    capture_outcome(result, out_path)
  end

  @doc """
  Turns how the Chromium *process* ended into whether we got a *screenshot* —
  and the file on disk wins.

  Chromium's `--timeout` stops a page that never finishes loading and writes the
  shot, but the process can then still hang on shutdown (a renderer stuck in the
  request that hung the page), so it is killed and reports a failure for a
  capture that actually succeeded. Discarding that file was the whole bug: the
  post got no screenshot even though the image already lay in the temp dir. A
  truncated file is no risk — framing it fails in `Vutuv.BrowserFrame.wrap/3`
  and the job retries.
  """
  def capture_outcome(result, out_path) do
    cond do
      File.exists?(out_path) -> :ok
      result == :ok -> {:error, :no_output_file}
      true -> result
    end
  end

  # System.cmd raises if the binary cannot be spawned (e.g. missing); keep that
  # inside the Task so capture/2 always returns a tagged tuple.
  defp safe_cmd(cmd, args) do
    {:ok, System.cmd(cmd, args, stderr_to_stdout: true)}
  rescue
    e -> {:error, {:spawn_failed, Exception.message(e)}}
  end

  # Prefer the `timeout` coreutil (`gtimeout` on macOS) so a hung Chromium is
  # force-killed at the OS level. Falls back to running Chromium directly when
  # neither is available (the Task backstop still applies).
  defp wrap_timeout(bin, args) do
    case System.find_executable("timeout") || System.find_executable("gtimeout") do
      nil -> {bin, args}
      timeout -> {timeout, ["--kill-after=#{@capture_grace}", "#{@capture_seconds}", bin | args]}
    end
  end

  @doc "Resolves the Chromium/Chrome binary to use, or `nil` if none is found."
  def binary do
    Application.get_env(:vutuv, :chromium_path) ||
      System.get_env("CHROMIUM_PATH") ||
      Enum.find_value(@candidate_binaries, &System.find_executable/1) ||
      Enum.find(@macos_paths, &File.exists?/1)
  end

  defp window_size do
    Application.get_env(:vutuv, :screenshot_window_size, @default_window)
  end

  defp tmp_path(prefix, id, ext) do
    name = "vutuv-#{prefix}-#{id}-#{System.unique_integer([:positive])}.#{ext}"
    Path.join(System.tmp_dir!(), name)
  end
end
