defmodule Vutuv.Moderation.Pixelation do
  @moduledoc """
  What a reader sees while the AI scan is still looking at a picture
  (issue #1720): the picture itself, reduced to 32 cells on its long edge and
  blown back up into flat blocks.

  Before this, an unreleased picture rendered as a grey hourglass tile for
  everyone but its author — honest, and a hole in the page. The pixelated
  preview keeps the card whole: the layout is right, the colours are the
  photo's own, and the moment `Vutuv.Moderation.ImageScans` releases the
  picture the live broadcast swaps the real one in.

  ## Why a second file and not a filter

  A CSS `filter: blur()` (or an `image-rendering` trick on the full-size file)
  sends the **whole picture** to the browser and asks it not to look. One
  devtools click undoes that, and any client that ignores our stylesheet never
  applied it in the first place. Here the pixels are thrown away before
  anything is served: `Vutuv.Uploads.Spec.write_pixelated/2` averages them into
  32 cells and that file is all a reader can fetch. What the scan has not
  cleared cannot leave, which is the same promise the grey tile made.

  It is still a **derivative of an unvetted picture**, which is the trade this
  makes: colours and rough composition of something nobody has looked at yet
  do reach readers. That is why the window below is short and why the coarse
  end of the recipe was chosen.

  ## The window

  A verdict normally lands in seconds. When it does not — the vision model is
  down, the queue is backed up — the preview must not sit on a public page
  indefinitely, so it stands in only for `window_seconds/0` (default an hour,
  `IMAGE_PIXELATION_WINDOW_SECONDS`). After that the card falls back to the
  grey tile it always had, and the release still swaps the picture in whenever
  it comes.

  **`0` turns the preview off** for the whole installation: an operator who
  wants nothing at all derived from an unvetted picture to be visible gets the
  old behaviour back with one env var, no code change.

  ## The file

  One file per picture, written beside the served versions by the storing
  context (it costs one shrink and one AVIF encode of a 32-cell image, i.e.
  next to nothing) and deleted the moment the scan settles — approved or
  rejected, both are answers, and neither needs a stand-in any more.

  A rejection takes the whole directory with it. An approval deletes the
  preview **before** it flips the state, so that an interruption between the
  two leaves a picture without its preview (the grey tile, for the last
  seconds of a wait that is ending) rather than an orphan file nothing will
  ever look at again.

  The name comes in two shapes, and this module owns both so that the three
  kinds cannot drift apart on it: `pixelated.avif` where the directory belongs
  to one picture for good (a post photo's token directory), and
  `pixelated-<hash>.avif` where the directory is reused as the picture is
  recaptured or refetched (link screenshots, pictures from other networks) and
  the served name has to change with the bytes.
  """

  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Uploads.Spec

  @window_seconds 3_600

  @doc """
  The filename a pixelated preview carries: `pixelated.avif`, or
  `pixelated-<hash>.avif` for the kinds whose directory outlives the picture
  in it (see the module doc).
  """
  def filename(hash \\ nil)
  def filename(nil), do: "pixelated#{Spec.served_ext()}"
  def filename(hash) when is_binary(hash), do: "pixelated-#{hash}#{Spec.served_ext()}"

  @doc "The preview's path inside a picture's served directory."
  def path(dir, hash \\ nil) when is_binary(dir), do: Path.join(dir, filename(hash))

  @doc """
  Writes the preview of an already-rotated image into `dir` — only where there
  is a wait to stand in for, since an installation with the AI scan switched
  off releases every picture on the spot.

  Best-effort, and so it always answers `:ok`: a preview that cannot be
  written costs the reader a grey tile, never the upload it belongs to. Any
  earlier preview in the directory goes first, so a recaptured picture can
  never leave a stale one answering its URL.
  """
  def write_if_enabled(image, dir, hash \\ nil) when is_binary(dir) do
    File.mkdir_p!(dir)
    clear(dir)

    if ImageScans.enabled?(), do: Spec.write_pixelated(image, path(dir, hash))

    :ok
  end

  @doc "Removes every pixelated preview in `dir`, whichever name shape it has."
  def clear(dir) when is_binary(dir) do
    dir
    |> Path.join("pixelated*")
    |> Path.wildcard()
    |> Enum.each(&File.rm/1)
  end

  @doc """
  How long a preview stands in for its picture. `0` disables it entirely (see
  the module doc).
  """
  def window_seconds,
    do: Application.get_env(:vutuv, :image_pixelation_window_seconds, @window_seconds)

  @doc """
  Whether a picture that started waiting at `started_at` is still inside the
  window.

  Reads the clock, so anything gated on it needs the config knob rather than a
  real hour to test both sides of the gate.
  """
  def within_window?(nil), do: false

  def within_window?(%NaiveDateTime{} = started_at) do
    window = window_seconds()

    window > 0 and NaiveDateTime.diff(NaiveDateTime.utc_now(), started_at) < window
  end

  @doc """
  Whether the preview at `path` stands in for its picture right now: inside the
  window, and actually on disk.

  The disk check is what keeps a tile from rendering as a broken image when the
  file is already gone (a settled scan, a swept leftover, an installation that
  turned the preview on after the picture was stored). It is paid only for a
  picture that is still waiting, which is a state measured in seconds.
  """
  def stands_in?(nil, _started_at), do: false

  def stands_in?(path, started_at) when is_binary(path) do
    within_window?(started_at) and File.exists?(path)
  end
end
