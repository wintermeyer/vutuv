defmodule Vutuv.Videos.Job do
  @moduledoc """
  Everything that happens to one clip after the upload (issues #1907–#1909),
  as a sequence of steps each of which is stamped on the row when it is done:

    1. **frames** — probe, pull the stills (opening frame, one every twenty
       seconds, the hard cuts), cut the default cover, queue one AI scan per
       still (`Vutuv.Videos.record_frames/3`).
    2. **h264** — the 720p file, with progress. Once it exists the clip is
       settled: ready if the check has passed, checking if not.
    3. **av1** — the 1080p enhancement, skipped where ffmpeg has no encoder.
    4. **lite** — the two 360p files for data-saving mode.

  `run/1` is what a resumed job runs too: it reads the stamps, skips what is
  done, sweeps the temporary file a killed encode left, and carries on. A
  step that fails on the H.264 file fails the clip (the author gets a way out
  through the pending card); a failing enhancement is logged, stamped so the
  scheduler stops offering it, and costs nothing else — the page offers what
  is on disk.

  Between steps the row is re-read: a frame verdict can refuse the clip while
  an encode runs, and the files that encode just wrote must go with the rest.
  """

  require Logger

  alias Vutuv.Posts.PostVideo
  alias Vutuv.PostVideoStore
  alias Vutuv.Videos
  alias Vutuv.Videos.FFmpeg

  # The H.264 percent is written to the row (and broadcast) at most this
  # often in percent points, so a two-minute encode costs a handful of writes
  # and not one per frame.
  @progress_step 2

  @doc "Runs every step still to do on `video_id`. Always releases the claim."
  def run(video_id) do
    case Videos.get_video(video_id) do
      nil ->
        :ok

      video ->
        PostVideoStore.clear_temp(video.token)

        result =
          with {:ok, video} <- step_frames(video),
               {:ok, video} <- step_rendition(video, "h264", :h264_ready_at),
               {:ok, video} <- step_rendition(video, "av1", :av1_ready_at),
               {:ok, video} <- step_lite(video) do
            {:ok, video}
          end

        case result do
          {:ok, video} -> Videos.release(video)
          {:stop, _video} -> :ok
        end

        :ok
    end
  end

  ## 1. Frames

  defp step_frames(%PostVideo{frames_extracted_at: nil} = video) do
    video = Videos.update_state(video, stage: "frames")

    with {:ok, original} <- original(video),
         {:ok, facts} <- FFmpeg.probe(original),
         {:ok, {frames, cover}} <- pull_frames(video, original, facts),
         {:ok, video} <- Videos.record_frames(video, frames, cover),
         :ok <- write_cover(video) do
      {:ok, video}
    else
      {:error, reason} -> {:stop, Videos.fail(video, {:frames, reason})}
    end
  end

  defp step_frames(video), do: continue(video)

  defp original(video) do
    case PostVideoStore.original_path(video.token) do
      nil -> {:error, :missing_original}
      path -> {:ok, path}
    end
  end

  # Which seconds get a still: the opening frame and the fixed ticks first
  # (they describe the whole clip evenly), the most representative opening
  # second (the default cover), then the hard cuts until the cap.
  defp pull_frames(video, original, facts) do
    duration = facts.duration_ms / 1000
    limit = Videos.max_frames()

    ticks =
      0
      |> Stream.iterate(&(&1 + Videos.frame_interval_seconds()))
      |> Enum.take_while(&(&1 < duration))

    cover_second = FFmpeg.representative_second(original, min(Videos.cover_window_seconds(), duration))
    Videos.heartbeat(video)
    cuts = FFmpeg.scene_cuts(original, limit)
    Videos.heartbeat(video)

    fixed = Enum.uniq([cover_second | ticks]) |> Enum.take(limit)
    chosen = Enum.uniq(fixed ++ Enum.reject(cuts, &(&1 in fixed))) |> Enum.take(limit)
    cut_set = MapSet.new(cuts) |> MapSet.difference(MapSet.new(fixed))

    PostVideoStore.clear_frames(video.token)

    written =
      chosen
      |> Enum.sort()
      |> Enum.reduce([], fn second, acc ->
        position = length(acc)

        case PostVideoStore.write_frame(video.token, position, second) do
          :ok -> [%{position: position, seconds: second, scene_cut: second in cut_set} | acc]
          {:error, _} -> acc
        end
      end)
      |> Enum.reverse()

    case written do
      [] ->
        {:error, :no_frames}

      frames ->
        cover = Enum.find(frames, &(&1.seconds == cover_second)) || List.first(frames)
        {:ok, {frames, cover.position}}
    end
  end

  defp write_cover(%PostVideo{cover_frame_id: nil}), do: :ok

  defp write_cover(video) do
    case Videos.cover_frame(video) do
      nil ->
        :ok

      frame ->
        with :ok <- PostVideoStore.write_cover(video.token, frame.position) do
          Videos.update_state(video, cover_written_at: DateTime.utc_now(:second))
          :ok
        end
    end
  end

  ## 2./3. The two main renditions

  defp step_rendition(video, name, stamp) do
    video = Videos.get_video(video.id) || video

    cond do
      PostVideo.refused?(video) ->
        {:stop, video}

      Map.get(video, stamp) != nil ->
        {:ok, video}

      name == "av1" and not PostVideoStore.av1_supported?() ->
        {:ok, Videos.update_state(video, av1_ready_at: DateTime.utc_now(:second))}

      true ->
        encode(video, name, stamp)
    end
  end

  defp encode(video, name, stamp) do
    video = if name == "h264", do: Videos.update_state(video, stage: "transcoding"), else: video

    with {:ok, original} <- original(video),
         {:ok, facts} <- FFmpeg.probe(original),
         :ok <- PostVideoStore.write_rendition(video.token, name, facts, progress_fun(video, name)) do
      after_rendition(video, name, stamp)
    else
      {:error, reason} when name == "h264" ->
        {:stop, Videos.fail(video, {:h264, reason})}

      {:error, reason} ->
        Logger.warning("post_video #{name} failed video=#{video.id} reason=#{inspect(reason)}")
        {:ok, Videos.update_state(video, [{stamp, DateTime.utc_now(:second)}])}
    end
  end

  # A verdict may have refused the clip while ffmpeg ran; the file it just
  # wrote goes with everything else, and the job stops.
  defp after_rendition(video, name, stamp) do
    fresh = Videos.get_video(video.id) || video

    if PostVideo.refused?(fresh) do
      PostVideoStore.delete(fresh.token)
      {:stop, fresh}
    else
      stamped = Videos.update_state(fresh, [{stamp, DateTime.utc_now(:second)}])
      if name == "h264", do: {:ok, Videos.settle(stamped)}, else: {:ok, stamped}
    end
  end

  # Only the H.264 file's progress reaches the row: it is the one the author
  # waits for. The enhancements refresh the heartbeat and nothing else.
  defp progress_fun(video, "h264") do
    fn percent ->
      if rem(percent, @progress_step) == 0 or percent == 100, do: Videos.set_progress(video, percent)
    end
  end

  defp progress_fun(video, _name) do
    fn percent -> if rem(percent, 10) == 0, do: Videos.heartbeat(video) end
  end

  ## 4. The data-saving pair

  defp step_lite(video) do
    video = Videos.get_video(video.id) || video

    cond do
      PostVideo.refused?(video) ->
        {:stop, video}

      video.lite_ready_at != nil ->
        {:ok, video}

      true ->
        encode_lite(video)
    end
  end

  defp encode_lite(video) do
    with {:ok, original} <- original(video),
         {:ok, facts} <- FFmpeg.probe(original) do
      names = if PostVideoStore.av1_supported?(), do: ["lite-av1", "lite-h264"], else: ["lite-h264"]

      Enum.each(names, fn name ->
        case PostVideoStore.write_rendition(video.token, name, facts, progress_fun(video, name)) do
          :ok -> :ok
          {:error, reason} -> Logger.warning("post_video #{name} failed video=#{video.id} reason=#{inspect(reason)}")
        end
      end)

      after_rendition(video, "lite", :lite_ready_at)
    else
      {:error, reason} ->
        Logger.warning("post_video lite failed video=#{video.id} reason=#{inspect(reason)}")
        {:ok, Videos.update_state(video, lite_ready_at: DateTime.utc_now(:second))}
    end
  end

  defp continue(video) do
    fresh = Videos.get_video(video.id) || video
    if PostVideo.refused?(fresh), do: {:stop, fresh}, else: {:ok, fresh}
  end
end
