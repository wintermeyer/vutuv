defmodule Vutuv.Organizations.OrganizationScreenshot do
  @moduledoc """
  An organization page's **homepage screenshot** — both the durable queue job
  and, once captured, the attachment record. Created for every organization
  that names a `website_url` (see `Vutuv.Organizations.Screenshots`).

  The row is the queue: a `pending`/`capturing`/`failed` row is work the
  `Vutuv.Organizations.ScreenshotWorker` drains, so a restart or a re-deploy
  mid-capture loses nothing; a `ready` row carries the stored capture.

  The stored file is served exactly like a profile link's screenshot: this row
  is the `Vutuv.Screenshot` scope (it has `.id`, `.screenshot`, `.updated_at`
  and a `moderation` column), so
  `Vutuv.Screenshot.url({s.screenshot, s}, :thumb)` yields the 400×264 AVIF
  thumb and `Vutuv.Screenshot.pixelated_url/1` the preview shown while the AI
  scan is still judging it.

  It is deliberately a table of its own rather than columns on `organizations`:
  the job's `updated_at` is when the *capture* happened, and that is what the
  pixelated preview's window is measured against — an organization's own
  `updated_at` moves every time somebody edits the page.

  All fields are set programmatically by the context (never cast from member
  params), so there is no public form changeset.
  """

  use VutuvWeb, :model

  alias Vutuv.Moderation.ImageScans

  @statuses ~w(pending capturing ready failed)

  schema "organization_screenshots" do
    belongs_to(:organization, Vutuv.Organizations.Organization)

    field(:url, :string)
    field(:status, :string, default: "pending")
    field(:screenshot, :string)
    field(:width, :integer)
    field(:height, :integer)
    field(:attempts, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime)
    field(:last_error, :string)
    field(:captured_at, :utc_datetime)

    # AI image moderation state (`Vutuv.Moderation.ImageScans`): a captured
    # homepage is held back ("pending") until the scan releases it.
    field(:moderation, :string)

    timestamps()
  end

  def statuses, do: @statuses

  @doc """
  Whether a capture is ready to render — captured **and** released by the AI
  image scan. A captured-but-unreleased screenshot shows to nobody, exactly
  like an uncaptured one (the file is not even in a served directory until the
  verdict; what a visitor sees meanwhile is the pixelated preview).
  """
  def ready?(%__MODULE__{status: "ready", screenshot: screenshot, moderation: moderation})
      when is_binary(screenshot),
      do: ImageScans.released?(moderation)

  def ready?(%__MODULE__{}), do: false

  @doc """
  The changeset that makes this row a fresh job for `url`: everything a
  previous capture left behind goes with it. Leaving `screenshot` or
  `moderation` in place would let the page serve a picture of the site it just
  stopped naming, and leaving `attempts` would spend a re-queued job's retries
  on the old URL's failures.

  The URL is capped at 2000 characters like the post queue's: the column is
  `text`, and Ecto enforces no limit of its own.
  """
  def enqueue_changeset(organization_screenshot, url) do
    organization_screenshot
    |> cast(%{url: url}, [:url])
    |> change(
      status: "pending",
      attempts: 0,
      next_attempt_at: nil,
      last_error: nil,
      screenshot: nil,
      moderation: nil,
      captured_at: nil
    )
    |> validate_required([:url])
    |> validate_length(:url, max: 2000)
    |> validate_inclusion(:status, @statuses)
  end
end
