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
  alias Vutuv.Profiles.Url
  alias Vutuv.Repo

  @candidate_binaries ~w(chromium chromium-browser google-chrome google-chrome-stable chrome)
  @macos_paths [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium"
  ]
  @default_window {1280, 800}
  # Hard ceiling for one Chromium run. `timeout` enforces it at the OS level
  # (and kills Chromium, so it can't be orphaned); the BEAM-side Task adds a
  # slightly looser backstop.
  @capture_seconds 30
  @capture_grace 5

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

  Marks the URL `broken?: false` on success and `broken?: true` on failure, so a
  failed page is not retried by the bulk `urls.create_screenshots` task. Safe
  to run from an unsupervised `Task` — all failures are logged, never raised.
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

      {:error, reason} ->
        Logger.warning(
          "screenshot generation failed for url ##{url.id} (#{url.value}): #{inspect(reason)}"
        )

        set_broken(url, true)
        :error
    end
  end

  # `url.value` is an untrusted member-supplied profile link. The changeset
  # already rejected literal internal hosts, but a public hostname can resolve
  # to an internal IP (DNS rebinding, issue #777), so resolve at capture time
  # and refuse before handing the URL to Chromium. This guards only the
  # profile path; `Vutuv.Moderation.EvidenceScreenshot` calls `capture/3`
  # directly to shoot the app's own host and is intentionally not gated.
  defp capture_and_frame(url) do
    if Vutuv.Ssrf.resolves_to_internal?(URI.parse(url.value).host) do
      {:error, :internal_target}
    else
      page_path = tmp_path("page", url.id, "png")
      framed_path = tmp_path("frame", url.id, "webp")

      try do
        with :ok <- capture(url.value, page_path),
             {:ok, ^framed_path} <- BrowserFrame.wrap(page_path, url.value, framed_path) do
          {:ok, framed_path}
        end
      after
        File.rm(page_path)
      end
    end
  end

  defp store(url, framed_path) do
    upload = %Plug.Upload{
      content_type: "image/webp",
      filename: "#{url.id}.webp",
      path: framed_path
    }

    url
    |> Url.changeset(%{screenshot: upload})
    |> Repo.update()
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
      nil ->
        {:error, :chromium_not_found}

      bin ->
        {width, height} = Keyword.get(opts, :window, window_size())

        # `--headless=new` already runs in a fresh throwaway profile per
        # invocation, so concurrent captures don't clash and nothing is left
        # behind in $HOME. `--disable-dev-shm-usage` avoids the small default
        # /dev/shm crashing Chromium on minimal server setups.
        args = [
          "--headless=new",
          "--disable-gpu",
          "--hide-scrollbars",
          "--no-sandbox",
          "--disable-dev-shm-usage",
          "--no-first-run",
          "--disable-extensions",
          "--force-device-scale-factor=1",
          "--virtual-time-budget=8000",
          "--window-size=#{width},#{height}",
          "--screenshot=#{out_path}",
          url
        ]

        run(bin, args, out_path)
    end
  end

  # Chromium can hang on hostile or dead pages. Wrap it in `timeout` so the
  # OS force-kills the process (its children follow) instead of leaving an
  # orphaned Chromium behind when the BEAM-side Task is shut down.
  defp run(bin, args, out_path) do
    {cmd, cmd_args} = wrap_timeout(bin, args)
    task = Task.async(fn -> safe_cmd(cmd, cmd_args) end)

    case Task.yield(task, (@capture_seconds + @capture_grace + 5) * 1000) || Task.shutdown(task) do
      {:ok, {:ok, {_output, 0}}} ->
        if File.exists?(out_path), do: :ok, else: {:error, :no_output_file}

      {:ok, {:ok, {output, code}}} ->
        {:error, {:exit_status, code, String.slice(output, 0, 500)}}

      {:ok, {:error, reason}} ->
        {:error, reason}

      _ ->
        {:error, :timeout}
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
