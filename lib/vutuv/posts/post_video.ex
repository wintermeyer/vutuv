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

  alias Vutuv.Posts.PostVideoFrame

  @stages ~w(queued frames transcoding checking ready rejected failed)
  @done_stages ~w(ready rejected failed)

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
