defmodule Vutuv.Videos.FFmpeg do
  @moduledoc """
  The one place vutuv talks to `ffmpeg` and `ffprobe` (issue #1907).

  Everything here is a shell-out with a bounded argument list and no shell:
  `probe/1` reads a container, `scene_cuts/2` and `representative_second/2`
  pick the seconds worth a still, `frame/4` pulls one, `transcode/3` writes a
  rendition and reports its progress line by line. Nothing parses a file name
  into an argument — every path comes from a store, never from a member.

  ## Progress

  `transcode/3` runs ffmpeg through a `Port` with `-progress pipe:1`, which
  makes ffmpeg print `out_time_us=…` on its stdout as it goes; divided by the
  clip's duration that is the percent the author watches. The port carries
  `:exit_status`, so a crash mid-encode is an error and not a truncated file
  that looks finished: every rendition is written to a temporary name beside
  its target and renamed only on exit 0 (`Vutuv.PostVideoStore`).

  ## CPU

  Every run is `nice`d and capped in threads (`:threads` in the
  `:post_videos` config): a member's upload must never be the thing that makes
  the site slow for everyone else. SVT-AV1 takes its cap as `lp`, which is a
  thread count on 4.x and a level 0–6 on the 2.x Debian ships — the value is
  clamped to 6, which means something sane on both.

  ## Availability

  `available?/0` answers whether both binaries can be run at all, probed once
  and cached for the VM's lifetime: an installation without ffmpeg simply has
  the feature off (`Vutuv.Videos.enabled?/0`), which is what an air-gapped
  intranet gets without setting anything.
  """

  @probe_timeout_ms 30_000
  # A two-minute 4K clip encodes to AV1 in about a minute on the production
  # host; ten minutes is the "something is wrong" ceiling, not a budget.
  @encode_timeout_ms :timer.minutes(10)

  @doc "Whether ffmpeg and ffprobe can be run on this machine (probed once)."
  def available? do
    case :persistent_term.get({__MODULE__, :available}, :unknown) do
      :unknown ->
        verdict = runs?(ffmpeg(), ["-version"]) and runs?(ffprobe(), ["-version"])
        :persistent_term.put({__MODULE__, :available}, verdict)
        verdict

      verdict ->
        verdict
    end
  end

  @doc false
  def forget_availability, do: :persistent_term.erase({__MODULE__, :available})

  @doc "Whether this ffmpeg build has encoder `name` (e.g. `libsvtav1`)."
  def encoder?(name) when is_binary(name) do
    case run(ffmpeg(), ["-hide_banner", "-encoders"], @probe_timeout_ms) do
      {:ok, out} -> Regex.match?(~r/^\s*[A-Z.]{6}\s+#{Regex.escape(name)}\s/m, out)
      {:error, _} -> false
    end
  end

  defp runs?(binary, args) do
    case System.find_executable(binary) do
      nil ->
        false

      path ->
        case System.cmd(path, args, stderr_to_stdout: true) do
          {_out, 0} -> true
          _ -> false
        end
    end
  rescue
    _ -> false
  end

  @doc """
  What the container holds: `{:ok, %{duration_ms:, width:, height:, fps:,
  video_codec:, audio?:}}` with the dimensions already swapped for a rotation
  the file's display matrix asks for (a phone's portrait clip is stored
  landscape plus "rotate 90"), or `{:error, :no_video}` / `{:error, :unreadable}`.
  """
  def probe(path) when is_binary(path) do
    args = [
      "-v",
      "error",
      "-show_entries",
      "format=duration:stream=index,codec_type,codec_name,width,height,r_frame_rate,avg_frame_rate:stream_side_data=rotation:stream_tags=rotate",
      "-of",
      "json",
      path
    ]

    with {:ok, out} <- run(ffprobe(), args, @probe_timeout_ms),
         {:ok, json} <- Jason.decode(out) do
      parse_probe(json)
    else
      {:error, _} -> {:error, :unreadable}
    end
  end

  defp parse_probe(%{"streams" => streams} = json) do
    case Enum.find(streams, &(&1["codec_type"] == "video")) do
      nil ->
        {:error, :no_video}

      video ->
        duration = parse_float(get_in(json, ["format", "duration"]))

        if sized?(video) and is_float(duration) and duration > 0 do
          {width, height} = rotate(video["width"], video["height"], rotation(video))

          {:ok,
           %{
             duration_ms: round(duration * 1000),
             width: width,
             height: height,
             fps: fps(video),
             video_codec: video["codec_name"],
             audio?: Enum.any?(streams, &(&1["codec_type"] == "audio"))
           }}
        else
          {:error, :unreadable}
        end
    end
  end

  defp parse_probe(_json), do: {:error, :unreadable}

  defp sized?(%{"width" => width, "height" => height})
       when is_integer(width) and is_integer(height),
       do: width > 0 and height > 0

  defp sized?(_video), do: false

  defp parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> nil
    end
  end

  defp parse_float(value) when is_number(value), do: value / 1
  defp parse_float(_), do: nil

  # A rotation lives in the display-matrix side data (modern) or a `rotate`
  # tag (older MOVs); either way ffmpeg applies it when decoding, so the
  # rendition comes out upright and the stored dimensions must say so.
  defp rotation(video) do
    side =
      video
      |> Map.get("side_data_list", [])
      |> Enum.find_value(fn data -> data["rotation"] end)

    tag = get_in(video, ["tags", "rotate"])

    (side || tag || 0)
    |> to_number()
    |> round()
    |> rem(360)
    |> abs()
  end

  defp to_number(value) when is_number(value), do: value

  defp to_number(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> 0
    end
  end

  defp to_number(_), do: 0

  defp rotate(width, height, rotation) when rotation in [90, 270], do: {height, width}
  defp rotate(width, height, _rotation), do: {width, height}

  defp fps(video) do
    rate = video["avg_frame_rate"] || video["r_frame_rate"] || "0/1"

    case String.split(to_string(rate), "/") do
      [num, den] ->
        with {n, _} <- Float.parse(num), {d, _} <- Float.parse(den), true <- d > 0 do
          n / d
        else
          _ -> 30.0
        end

      _ ->
        30.0
    end
  end

  @doc """
  The seconds at which the picture changes hard, found on a 320-pixel copy
  (scene detection on the full frame was the single most expensive step,
  measured), whole seconds, deduplicated, at most `limit` of them.
  """
  def scene_cuts(path, limit) when is_binary(path) and is_integer(limit) do
    args =
      base_args() ++
        [
          "-i",
          path,
          "-vf",
          "scale=320:-2,select='gt(scene,0.4)',showinfo",
          "-fps_mode",
          "vfr",
          "-an",
          "-f",
          "null",
          "-"
        ]

    case run(ffmpeg(), args, @encode_timeout_ms) do
      {:ok, out} ->
        out
        |> showinfo_seconds()
        |> Enum.uniq()
        |> Enum.take(limit)

      {:error, _} ->
        []
    end
  end

  @doc """
  The second of the most representative frame of the clip's opening
  `window` seconds (ffmpeg's `thumbnail` filter), or `0` when it cannot say.
  """
  def representative_second(path, window) when is_binary(path) do
    args =
      base_args() ++
        [
          "-t",
          "#{window}",
          "-i",
          path,
          "-vf",
          "scale=320:-2,thumbnail=90,showinfo",
          "-frames:v",
          "1",
          "-an",
          "-f",
          "null",
          "-"
        ]

    case run(ffmpeg(), args, @encode_timeout_ms) do
      {:ok, out} -> out |> showinfo_seconds() |> List.first() || 0
      {:error, _} -> 0
    end
  end

  # showinfo logs one `pts_time:12.34` per frame that passed the filter chain.
  defp showinfo_seconds(out) do
    ~r/pts_time:\s*(\d+(?:\.\d+)?)/
    |> Regex.scan(out)
    |> Enum.map(fn [_, secs] ->
      {value, _} = Float.parse(secs)
      trunc(value)
    end)
  end

  @doc """
  Writes the frame at `second` as a JPEG to `dest`, at most `max_width` wide.
  """
  def frame(path, second, dest, max_width) when is_binary(path) and is_binary(dest) do
    args =
      base_args() ++
        [
          "-ss",
          "#{second}",
          "-i",
          path,
          "-frames:v",
          "1",
          "-vf",
          "scale='min(#{max_width},iw)':-2",
          "-q:v",
          "3",
          "-an",
          "-y",
          dest
        ]

    case run(ffmpeg(), args, @probe_timeout_ms) do
      {:ok, _} -> if File.exists?(dest), do: :ok, else: {:error, :no_frame}
      {:error, reason} -> {:error, reason}
    end
  end

  @typedoc """
  A rendition recipe: the codec-side arguments (`Vutuv.Videos.Recipes`),
  the target file, and the clip's duration for the percent.
  """
  @type transcode_opts :: [
          args: [String.t()],
          duration_ms: pos_integer(),
          on_progress: (0..100 -> any()),
          timeout: pos_integer()
        ]

  @doc """
  Transcodes `path` to `dest` with the codec arguments in `opts[:args]`,
  calling `opts[:on_progress]` with a percent as ffmpeg advances. Returns
  `:ok` or `{:error, reason}`; on an error `dest` is removed, so a target
  that exists is a finished one.
  """
  def transcode(path, dest, opts) when is_binary(path) and is_binary(dest) do
    args =
      base_args() ++
        ["-i", path] ++
        Keyword.fetch!(opts, :args) ++
        ["-progress", "pipe:1", "-nostats", "-y", dest]

    duration_ms = Keyword.fetch!(opts, :duration_ms)
    on_progress = Keyword.get(opts, :on_progress, fn _ -> :ok end)
    timeout = Keyword.get(opts, :timeout, @encode_timeout_ms)

    case stream(ffmpeg(), args, timeout, progress_parser(duration_ms, on_progress)) do
      :ok ->
        if File.exists?(dest), do: :ok, else: {:error, :no_output}

      {:error, reason} ->
        File.rm(dest)
        {:error, reason}
    end
  end

  # ffmpeg's -progress output is `key=value` lines; `out_time_us` is the
  # encoded position in microseconds. Percent is clamped: the last block can
  # overshoot the probed duration by a frame.
  defp progress_parser(duration_ms, on_progress) do
    fn
      "out_time_us=" <> us, last -> report(percent_of(us, duration_ms), last, on_progress)
      _line, last -> last
    end
  end

  defp percent_of(us, duration_ms) do
    case Integer.parse(String.trim(us)) do
      {micro, _} when micro >= 0 -> min(100, div(micro, max(duration_ms * 10, 1)))
      _ -> nil
    end
  end

  # Only a changed percent reaches the callback (and the row behind it).
  defp report(nil, last, _on_progress), do: last
  defp report(percent, last, _on_progress) when percent == last, do: last

  defp report(percent, _last, on_progress) do
    on_progress.(percent)
    percent
  end

  ## Running

  # Flags every ffmpeg run shares: never read the terminal, log only errors,
  # and treat the frame timestamps as they are.
  defp base_args, do: ["-nostdin", "-hide_banner", "-loglevel", "error"]

  # `run/3` collects everything and answers `{:ok, output}` on exit 0. Used
  # for the short jobs (probe, stills, scene detection), whose output is what
  # they say.
  defp run(binary, args, timeout) do
    {cmd, cmd_args} = command(binary, args)

    port =
      Port.open({:spawn_executable, cmd}, [
        :binary,
        :stream,
        :exit_status,
        :stderr_to_stdout,
        args: cmd_args
      ])

    collect(port, [], timeout)
  end

  defp collect(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect(port, [acc, data], timeout)

      {^port, {:exit_status, 0}} ->
        {:ok, IO.iodata_to_binary(acc)}

      {^port, {:exit_status, status}} ->
        {:error, {:exit, status, clip(IO.iodata_to_binary(acc))}}
    after
      timeout ->
        close(port)
        {:error, :timeout}
    end
  end

  # `stream/4` hands every complete line to `parser` as it arrives (the
  # progress feed) and answers `:ok` on exit 0.
  defp stream(binary, args, timeout, parser) do
    {cmd, cmd_args} = command(binary, args)

    port =
      Port.open({:spawn_executable, cmd}, [
        :binary,
        :stream,
        :exit_status,
        :stderr_to_stdout,
        args: cmd_args
      ])

    consume(port, "", nil, [], timeout, parser)
  end

  defp consume(port, buffer, state, log, timeout, parser) do
    receive do
      {^port, {:data, data}} ->
        {lines, rest} = split_lines(buffer <> data)
        state = Enum.reduce(lines, state, fn line, acc -> parser.(line, acc) end)
        consume(port, rest, state, keep_log(log, lines), timeout, parser)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, status}} ->
        {:error, {:exit, status, clip(Enum.join(log, "\n"))}}
    after
      timeout ->
        close(port)
        {:error, :timeout}
    end
  end

  defp split_lines(data) do
    case String.split(data, "\n") do
      [rest] -> {[], rest}
      parts -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  # Only ffmpeg's own error lines are worth keeping for the failure record;
  # the progress feed would be thousands of `frame=` lines.
  defp keep_log(log, lines) do
    errors = Enum.reject(lines, &String.contains?(&1, "="))
    Enum.take(log ++ errors, 20)
  end

  defp clip(text), do: String.slice(text, 0, 2_000)

  defp close(port) do
    Port.close(port)
  rescue
    _ -> :ok
  end

  # The command is `nice -n 19 <binary> args…` where `nice` exists (Linux,
  # macOS), the bare binary where it does not. The binary is resolved once
  # here, so a configured name that is not on `$PATH` fails as a clear
  # `:enoent` rather than a shell error.
  defp command(binary, args) do
    path = System.find_executable(binary) || binary

    case System.find_executable("nice") do
      nil -> {path, args}
      nice -> {nice, ["-n", "19", path | args]}
    end
  end

  defp ffmpeg, do: Keyword.get(config(), :ffmpeg, "ffmpeg")
  defp ffprobe, do: Keyword.get(config(), :ffprobe, "ffprobe")

  @doc "The thread cap every encode runs under."
  def threads, do: max(1, Keyword.get(config(), :threads, 4))

  defp config, do: Application.get_env(:vutuv, :post_videos, [])
end
