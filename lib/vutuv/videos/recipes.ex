defmodule Vutuv.Videos.Recipes do
  @moduledoc """
  The four renditions a clip is turned into (issues #1907 and #1924), as
  ffmpeg argument lists — one function per file, so the codec choices live
  in one place and the store only names the file.

    * `h264` — 720p H.264 High, `crf 23`, `maxrate 2500k`, AAC 128k. The
      profile Mastodon copies without re-encoding, so it is the one file that
      federates, and the fallback every browser plays.
    * `av1` — 1080p AV1 (SVT-AV1 preset 8, `crf 35`), about half the bytes of
      the H.264 at the same quality, offered first to browsers that decode it.
    * `lite_h264` / `lite_av1` — 360p twins with 48 kbit/s mono AAC for
      data-saving mode: together under two megabytes for a two-minute talk
      against 37 for the 720p file (measured, VMAF phone model).

  The "720p" of a rendition caps the clip's **shorter** side, so a phone's
  portrait clip comes out 720 wide and 1280 tall rather than a 405-pixel
  sliver. `-2` keeps the other side even, which every yuv420p encoder needs.
  Frame rate is capped, never raised: a 60 fps source drops to 30, a 24 fps
  one stays 24.
  """

  alias Vutuv.Videos.FFmpeg

  @doc "The H.264 720p rendition — the file that federates."
  def h264(fps) do
    common(720, fps, 30) ++
      [
        "-c:v",
        "libx264",
        "-profile:v",
        "high",
        "-level",
        "4.0",
        "-pix_fmt",
        "yuv420p",
        "-crf",
        "23",
        "-maxrate",
        "2500k",
        "-bufsize",
        "5000k",
        "-preset",
        "medium",
        "-g",
        "120",
        "-threads",
        "#{FFmpeg.threads()}",
        "-c:a",
        "aac",
        "-b:a",
        "128k",
        "-ac",
        "2"
      ] ++ mp4()
  end

  @doc "The AV1 1080p rendition — offered first to browsers that decode it."
  def av1(fps) do
    common(1080, fps, 30) ++
      svt(35) ++
      ["-c:a", "aac", "-b:a", "128k", "-ac", "2"] ++ mp4()
  end

  @doc "The 360p H.264 file for data-saving mode."
  def lite_h264(fps) do
    common(360, fps, 24) ++
      [
        "-c:v",
        "libx264",
        "-profile:v",
        "main",
        "-pix_fmt",
        "yuv420p",
        "-crf",
        "32",
        "-maxrate",
        "350k",
        "-bufsize",
        "700k",
        "-preset",
        "slow",
        "-g",
        "96",
        "-threads",
        "#{FFmpeg.threads()}"
      ] ++ lite_audio() ++ mp4()
  end

  @doc "The 360p AV1 file for data-saving mode — the smallest file of the four."
  def lite_av1(fps) do
    common(360, fps, 24) ++ svt(55) ++ lite_audio() ++ mp4()
  end

  # The first video stream and, when there is one, the first audio stream;
  # subtitles and data tracks stay behind.
  defp common(short_side, fps, fps_cap) do
    ["-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn", "-vf", filter(short_side, fps, fps_cap)]
  end

  # Cap the shorter side, keep the aspect, keep both sides even. Quoted for
  # ffmpeg's own filter parser (there is no shell in between): the commas
  # inside `min(…)` and `if(…)` would otherwise split the option.
  defp filter(short_side, fps, fps_cap) do
    scale =
      "scale=w='if(gt(iw,ih),-2,trunc(min(iw,#{short_side})/2)*2)':" <>
        "h='if(gt(iw,ih),trunc(min(ih,#{short_side})/2)*2,-2)'"

    if is_number(fps) and fps > fps_cap + 0.5, do: "#{scale},fps=#{fps_cap}", else: scale
  end

  # SVT-AV1: `lp` is a thread count on 4.x and a level of parallelism (0–6)
  # on the 2.x Debian ships; clamped to 6 it is a sane value on both.
  defp svt(crf) do
    [
      "-c:v",
      "libsvtav1",
      "-preset",
      "8",
      "-crf",
      "#{crf}",
      "-pix_fmt",
      "yuv420p",
      "-g",
      "120",
      "-svtav1-params",
      "lp=#{min(FFmpeg.threads(), 6)}"
    ]
  end

  # At 360p the sound is half the file: AAC-LC 48k mono is the floor old
  # Safari still plays (Opus would be smaller and would not).
  defp lite_audio, do: ["-c:a", "aac", "-b:a", "48k", "-ac", "1"]

  # `faststart` moves the index to the front so playback starts before the
  # whole file is down — and so a range request for the head finds it.
  defp mp4, do: ["-movflags", "+faststart", "-f", "mp4"]
end
