defmodule Vutuv.PostVideoStore do
  @moduledoc """
  On-disk storage for post videos (issue #1907).

  Like post images there is **no public tree**: every served byte goes through
  the authorizing proxy (`VutuvWeb.PostVideoController`), which also answers
  the byte-range requests a `<video>` element makes. The renditions live in
  one directory per clip, keyed by the clip's URL token; the upload itself and
  the stills pulled for the AI check sit in the private `originals/` tree:

      <uploads_dir_prefix>/post_videos/<token>/h264.mp4          720p, the file that federates
                                              /av1.mp4           1080p, for browsers that decode it
                                              /lite-h264.mp4     360p, data-saving mode
                                              /lite-av1.mp4      360p, data-saving mode
                                              /cover.avif        the poster (1200 px)
                                              /cover-lite.avif   the poster for data-saving mode (640 px)
      <uploads_dir_prefix>/originals/post_videos/<token>/original.<ext>
                                                       /frames/00.jpg … 23.jpg

  The original leaves the server on **no path**: the proxy resolves only the
  names in `served_files/0`, and there is no download switch as photos have —
  the renditions are the whole offer. It is kept so a later codec change can
  re-derive every file from the upload rather than from a rendition.

  Every rendition is written to a temporary name beside its target and
  renamed on success, so a process killed mid-encode leaves no half file a
  proxy could serve: a target that exists is a finished one, which is what
  lets `Vutuv.Videos.Job` resume by looking at the disk.
  """

  alias Vutuv.Uploads.Originals
  alias Vutuv.Uploads.Spec
  alias Vutuv.Videos.FFmpeg
  alias Vutuv.Videos.Recipes

  # The containers a phone or a screen recorder writes. `.m4v` is deliberately
  # absent: LiveView's upload `accept` needs a MIME type for every extension
  # and the MIME table has none for it; an `.m4v` renamed to `.mp4` is the
  # same file.
  @extension_whitelist ~w(.mp4 .mov .webm)
  @renditions ~w(h264 av1 lite-h264 lite-av1)
  @served_files ~w(h264.mp4 av1.mp4 lite-h264.mp4 lite-av1.mp4 cover.avif cover-lite.avif)
  # The stills are at most this wide: enough for the vision model and the
  # cover, a fraction of a 4K frame.
  @frame_width 1280
  @cover_quality 58

  def extension_whitelist, do: @extension_whitelist
  def renditions, do: @renditions

  @doc "The file names the proxy resolves — nothing else in the directory is reachable."
  def served_files, do: @served_files

  @doc """
  Copies the upload at `path` into the private tree under a fresh `token`.
  Returns `{:ok, %{content_type:, size_bytes:}}` or `{:error, :invalid_file}`
  when the extension is not whitelisted. Nothing is decoded here — that is
  `Vutuv.Videos.FFmpeg.probe/1`'s job, done before this is called.
  """
  def store_original(path, filename, token) do
    if Vutuv.Uploads.valid_extension?(filename, @extension_whitelist) do
      ext = filename |> Path.extname() |> String.downcase()
      :ok = Originals.store(storage_dir(token), path, ext)
      File.mkdir_p!(dir(token))

      {:ok,
       %{
         content_type: MIME.from_path(filename),
         size_bytes: File.stat!(path).size
       }}
    else
      {:error, :invalid_file}
    end
  end

  @doc "The kept upload, or `nil` when it is gone."
  def original_path(token), do: Originals.path(storage_dir(token))

  ## Frames

  @doc "Where the still at `position` lives (whether or not it has been written)."
  def frame_path(token, position) when is_integer(position) do
    Path.join(frames_dir(token), frame_name(position))
  end

  defp frame_name(position), do: String.pad_leading("#{position}", 2, "0") <> ".jpg"

  defp frames_dir(token), do: Path.join(Originals.dir(storage_dir(token)), "frames")

  @doc "Writes the still at `second` of the original as frame `position`."
  def write_frame(token, position, second) do
    case original_path(token) do
      nil ->
        {:error, :missing_original}

      original ->
        File.mkdir_p!(frames_dir(token))
        FFmpeg.frame(original, second, frame_path(token, position), @frame_width)
    end
  end

  @doc "Removes every still, so a re-run starts from none."
  def clear_frames(token) do
    File.rm_rf(frames_dir(token))
    :ok
  end

  ## Renditions

  @doc "Absolute path of a finished rendition (`h264` | `av1` | `lite-h264` | `lite-av1`), or `nil`."
  def rendition_path(token, name) when name in @renditions do
    path = Path.join(dir(token), "#{name}.mp4")
    if File.exists?(path), do: path
  end

  @doc """
  Encodes rendition `name` from the original, reporting progress through
  `on_progress` (a percent). `:ok` once the file is in place, or
  `{:error, reason}` with nothing left behind.
  """
  def write_rendition(token, name, facts, on_progress) when name in @renditions do
    case original_path(token) do
      nil ->
        {:error, :missing_original}

      original ->
        dir = dir(token)
        File.mkdir_p!(dir)
        dest = Path.join(dir, "#{name}.mp4")
        temp = Path.join(dir, ".#{name}.#{System.unique_integer([:positive])}.mp4")

        result =
          FFmpeg.transcode(original, temp,
            args: recipe(name, facts.fps),
            duration_ms: facts.duration_ms,
            on_progress: on_progress
          )

        case result do
          :ok ->
            File.rename!(temp, dest)
            :ok

          {:error, _} = error ->
            File.rm(temp)
            error
        end
    end
  end

  defp recipe("h264", fps), do: Recipes.h264(fps)
  defp recipe("av1", fps), do: Recipes.av1(fps)
  defp recipe("lite-h264", fps), do: Recipes.lite_h264(fps)
  defp recipe("lite-av1", fps), do: Recipes.lite_av1(fps)

  @doc "Drops the temporary files a killed encode left behind."
  def clear_temp(token) do
    token
    |> dir()
    |> Path.join(".*.mp4")
    |> Path.wildcard(match_dot: true)
    |> Enum.each(&File.rm/1)
  end

  @doc """
  Whether this ffmpeg can write AV1 at all (an installation whose build lacks
  `libsvtav1` still gets the H.264 files). Probed once per VM.
  """
  def av1_supported? do
    case :persistent_term.get({__MODULE__, :av1}, :unknown) do
      :unknown ->
        verdict = FFmpeg.encoder?("libsvtav1")
        :persistent_term.put({__MODULE__, :av1}, verdict)
        verdict

      verdict ->
        verdict
    end
  end

  ## The cover

  @doc "Absolute path of the poster (`:full` or `:lite`), or `nil` when not written."
  def cover_path(token, size) when size in [:full, :lite] do
    path = Path.join(dir(token), cover_name(size))
    if File.exists?(path), do: path
  end

  defp cover_name(:full), do: "cover.avif"
  defp cover_name(:lite), do: "cover-lite.avif"

  @doc """
  Cuts the poster from the still at `position`: the feed-size AVIF and its
  640 px data-saving twin, metadata-stripped like every served picture.
  """
  def write_cover(token, position) do
    frame = frame_path(token, position)

    with true <- File.exists?(frame) || {:error, :missing_frame},
         {:ok, rotated} <- Spec.open_rotated(frame),
         :ok <- write_cover_file(rotated, token, :full, 1200),
         :ok <- write_cover_file(rotated, token, :lite, 640) do
      :ok
    end
  end

  defp write_cover_file(image, token, size, box) do
    dest = Path.join(dir(token), cover_name(size))
    temp = "#{dest}.#{System.unique_integer([:positive])}"

    case Spec.write_derived(%{fit: {:box_down, box}, quality: @cover_quality}, image, temp) do
      :ok ->
        File.rename!(temp, dest)
        :ok

      error ->
        File.rm(temp)
        error
    end
  end

  @doc """
  The cover as JPEG bytes for link previews (`og:image`) and the Fediverse
  attachment's icon — scrapers do not decode AVIF. Derived on the fly from
  the cover frame, width-capped at 1200 px and metadata-stripped.
  """
  def og_jpeg(token, position) when is_integer(position) do
    Spec.og_jpeg(frame_path(token, position), &Image.thumbnail(&1, "1200", resize: :down))
  end

  ## nginx

  @doc "The path nginx resolves inside its `internal` alias location (X-Accel mode)."
  def accel_path(token, file) when file in @served_files, do: "/internal_post_videos/#{token}/#{file}"

  @doc "Absolute on-disk path of a served file, or `nil` when it is missing."
  def served_path(token, file) when file in @served_files do
    path = Path.join(dir(token), file)
    if File.exists?(path), do: path
  end

  ## Deleting

  @doc "Removes every stored file of `token`: renditions, cover, stills and the original."
  def delete(token) when is_binary(token) do
    File.rm_rf(dir(token))
    Originals.delete(storage_dir(token))
    :ok
  end

  defp storage_dir(token) do
    # The token is Base64-URL by construction, but never trust a stored value
    # enough to build paths with separators in it.
    false = String.contains?(token, ["/", ".."])
    Path.join("post_videos", token)
  end

  defp dir(token), do: Vutuv.Uploads.disk_dir(storage_dir(token))
end
