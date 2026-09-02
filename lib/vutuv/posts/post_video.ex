defmodule Vutuv.Posts.PostVideo do
  @moduledoc """
  The clip a post carries (issue #1906) — at most one per post.

  Uploaded eagerly like a post image: the composer stores it the moment the
  file lands, so `post_id` stays `nil` until the post is submitted, and the
  pipeline (`Vutuv.Videos.Pipeline`) starts on it while the author is still
  writing. Unattached rows older than a day are swept
  (`Vutuv.Videos.sweep_pending_videos/0`).

  ## What the row holds

    * **the upload's facts** — `content_type`, `size_bytes`, and what ffprobe
      read: `duration_ms`, `width`/`height` after the rotation the file asks
      for.
    * **where the pipeline is** — `stage` for people (`queued` → `frames` →
      `transcoding` → `checking` → `ready`, or `rejected` / `failed`),
      `progress` as the H.264 rendition's percent while `transcoding`, and one
      stamp per finished step (`frames_extracted_at`, `h264_ready_at`,
      `av1_ready_at`, `lite_ready_at`, `cover_written_at`) — the stamps are what
      a resumed job reads, so a deploy that kills the process mid-encode costs
      the one rendition it was on, never the ones before it.
    * **the AI verdict** — `moderation` over every frame (`Vutuv.Posts.
      PostVideoFrame`), and `rejected_second` for the frame that refused it.
    * **the cover** — `cover_frame_id`, the frame the poster is cut from: the
      pipeline's pick until the author clicks another.
    * **`alt`** — like a photo's.

  A clip is **ready** once the H.264 file exists and the check passed; the AV1
  and the two 360p files come after, as enhancements, and a page simply offers
  what is on disk (`Vutuv.PostVideoStore.sources/1`).

  The original stays in the private `originals/` tree and leaves the server on
  no path at all — unlike a photo there is no download switch: the served
  renditions are the whole offer.
  """

  use VutuvWeb, :model

  alias Vutuv.LowBandwidth
  alias Vutuv.Posts.PostVideoFrame
  alias Vutuv.PostVideoStore

  @stages ~w(queued frames transcoding checking ready rejected failed)
  @done_stages ~w(ready rejected failed)
  # AV1 Main 8-bit, level 4.0 — what the SVT recipe writes — and H.264 High
  # 4.0 with AAC-LC. The strings are what `canPlayType` is asked.
  @av1_type ~s(video/mp4; codecs="av01.0.08M.08, mp4a.40.2")
  @h264_type ~s(video/mp4; codecs="avc1.640028, mp4a.40.2")

  schema "post_videos" do
    belongs_to(:post, Vutuv.Posts.Post)
    belongs_to(:user, Vutuv.Accounts.User)

    field(:token, :string)
    field(:alt, :string, default: "")

    field(:content_type, :string)
    field(:size_bytes, :integer)
    field(:duration_ms, :integer)
    field(:width, :integer)
    field(:height, :integer)

    field(:stage, :string, default: "queued")
    field(:progress, :integer, default: 0)
    field(:error, :string)

    field(:moderation, :string, default: "pending")
    field(:rejected_second, :integer)

    field(:frames_extracted_at, :utc_datetime)
    field(:h264_ready_at, :utc_datetime)
    field(:av1_ready_at, :utc_datetime)
    field(:lite_ready_at, :utc_datetime)
    field(:cover_written_at, :utc_datetime)
    field(:worked_at, :utc_datetime)

    belongs_to(:cover_frame, PostVideoFrame)
    has_many(:frames, PostVideoFrame, foreign_key: :video_id, preload_order: [asc: :position])

    timestamps()
  end

  def stages, do: @stages

  @doc "Whether the pipeline has nothing left to decide about this clip."
  def done?(%__MODULE__{stage: stage}), do: stage in @done_stages

  @doc "Whether the clip may be shown and played: the check passed and the H.264 file exists."
  def ready?(%__MODULE__{stage: "ready"}), do: true
  def ready?(%__MODULE__{}), do: false

  @doc "Whether the clip can no longer become ready — the post has to go without it."
  def refused?(%__MODULE__{stage: stage}), do: stage in ~w(rejected failed)

  def alt_changeset(video, params) do
    video
    |> cast(params, [:alt])
    |> update_change(:alt, &String.trim/1)
    |> validate_length(:alt, max: 255)
  end

  @doc "A fresh unguessable URL token (~128 bits, URL-safe)."
  defdelegate gen_token, to: Vutuv.Uploads

  ## URLs — one owner, like `Vutuv.Posts.PostImage`

  @doc "Root-relative proxy URL of one served file (`h264.mp4`, `cover.avif`, …)."
  def url(%__MODULE__{token: token}, file) when is_binary(file),
    do: "#{token_prefix(token)}#{file}"

  @doc """
  The poster's URL. It carries the cover frame's id as a cache buster: the
  proxy serves every file as immutable for a year, and the author may pick
  another frame, which rewrites the file under the same name.
  """
  def cover_url(%__MODULE__{} = video), do: url(video, "cover.avif") <> cover_buster(video)

  @doc "The `%{src:, lite:}` pair `VutuvWeb.UI.picture/1` renders for the poster."
  def cover_picture(%__MODULE__{} = video) do
    LowBandwidth.picture(cover_url(video), fn ->
      if video.cover_written_at, do: url(video, "cover-lite.avif") <> cover_buster(video)
    end)
  end

  @doc "The link-preview JPEG (`og:image`, the Fediverse attachment's icon)."
  def og_url(%__MODULE__{} = video), do: url(video, "cover.jpg") <> cover_buster(video)

  @doc "The author-only URL of one still in the strip."
  def frame_url(%__MODULE__{} = video, %PostVideoFrame{position: position}),
    do: url(video, "frame-#{String.pad_leading("#{position}", 2, "0")}.jpg")

  defp cover_buster(%__MODULE__{cover_frame_id: nil}), do: ""
  defp cover_buster(%__MODULE__{cover_frame_id: id}), do: "?v=" <> binary_part(id, 24, 12)

  @doc """
  The `<source>` list the player offers, best first: the AV1 file where a
  browser decodes it (the `codecs` string is what lets Safari without an AV1
  decoder skip it), the H.264 file for everyone — and for a viewer in
  data-saving mode the two 360p files ahead of both (issue #1924). Only files
  that exist are named, so a clip whose enhancements are still being written
  plays from what is there.
  """
  def sources(%__MODULE__{} = video) do
    lite =
      if LowBandwidth.on?() and video.lite_ready_at,
        do: [{"lite-av1", @av1_type}, {"lite-h264", @h264_type}],
        else: []

    (lite ++ [{"av1", @av1_type}, {"h264", @h264_type}])
    |> Enum.filter(fn {name, _type} -> PostVideoStore.rendition_path(video.token, name) end)
    |> Enum.map(fn {name, type} -> %{src: url(video, "#{name}.mp4"), type: type} end)
  end

  @doc "Whether the data-saving viewer is being offered the 360p files (the HD control's cue)."
  def lite_offered?(%__MODULE__{} = video), do: LowBandwidth.on?() and video.lite_ready_at != nil

  defp token_prefix(token), do: "/post_videos/#{token}/"

  @doc "The clip's aspect ratio (width / height), or 16:9 when the dimensions are missing."
  def aspect(%__MODULE__{width: width, height: height})
      when is_integer(width) and is_integer(height) and width > 0 and height > 0,
      do: width / height

  def aspect(%__MODULE__{}), do: 16 / 9

  @doc "The length in whole seconds, rounded up — what every label and the API say."
  def seconds(%__MODULE__{duration_ms: ms}) when is_integer(ms) and ms > 0,
    do: div(ms + 999, 1000)

  def seconds(%__MODULE__{}), do: 0

  @doc "The length as an ISO 8601 duration (`PT1M30S`), the ActivityPub spelling."
  def iso8601_duration(%__MODULE__{} = video) do
    total = seconds(video)
    minutes = div(total, 60)
    secs = rem(total, 60)

    case {minutes, secs} do
      {0, s} -> "PT#{s}S"
      {m, 0} -> "PT#{m}M"
      {m, s} -> "PT#{m}M#{s}S"
    end
  end
end
