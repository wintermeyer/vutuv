defmodule Vutuv.Posts.PostScreenshot do
  @moduledoc """
  A post's auto-generated **link screenshot** — both the durable queue job and,
  once captured, the attachment record. Created for a post that carries a single
  URL and no image (see `Vutuv.Posts.Screenshots`).

  The row is the queue: a `pending`/`capturing`/`failed` row is work the
  `Vutuv.Posts.ScreenshotWorker` drains, so a restart or re-deploy loses
  nothing; a `ready` row carries the stored screenshot. All fields are set
  programmatically by the context (never cast from member params), so there is
  no public form changeset — state transitions go through
  `Ecto.Changeset.change/2` in `Vutuv.Posts.Screenshots`.

  The stored file is served exactly like a profile link's screenshot: this row
  is the `Vutuv.Screenshot` scope (it has `.id` + `.screenshot`), so
  `Vutuv.Screenshot.url({ps.screenshot, ps}, :thumb)` yields the 400×264 AVIF
  thumb with the `/images/screenshot.png` fallback.
  """

  use VutuvWeb, :model

  alias Vutuv.Moderation.ImageScans

  @statuses ~w(pending capturing ready failed)

  schema "post_screenshots" do
    belongs_to(:post, Vutuv.Posts.Post)

    field(:url, :string)
    field(:status, :string, default: "pending")
    field(:screenshot, :string)
    field(:width, :integer)
    field(:height, :integer)
    field(:attempts, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime)
    field(:last_error, :string)
    field(:captured_at, :utc_datetime)

    # AI image moderation state (Vutuv.Moderation.ImageScans): a captured
    # screenshot is held back ("pending") until the scan releases it.
    field(:moderation, :string)

    timestamps()
  end

  def statuses, do: @statuses

  @doc """
  Whether a captured screenshot is ready to render — captured **and**
  released by the AI image scan (a captured-but-unreleased screenshot shows
  to nobody, exactly like an uncaptured one).
  """
  def ready?(%__MODULE__{status: "ready", screenshot: screenshot, moderation: moderation})
      when is_binary(screenshot),
      do: ImageScans.released?(moderation)

  def ready?(%__MODULE__{}), do: false

  @doc """
  The enqueue changeset for a new/refreshed job — the URL and a `pending` reset.
  `url` is a bare `http(s)` string extracted from the post body (`text` column,
  but capped so a pathological URL can't blow past a sane length).
  """
  def enqueue_changeset(post_screenshot, url) do
    post_screenshot
    |> cast(%{url: url, status: "pending"}, [:url, :status])
    |> validate_required([:url])
    |> validate_length(:url, max: 2000)
    |> validate_inclusion(:status, @statuses)
  end
end
