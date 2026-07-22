defmodule Vutuv.Moderation.ImageScan do
  @moduledoc """
  One AI image-moderation job — both the durable queue entry and, once
  resolved, the audit record (the `Vutuv.Posts.PostScreenshot` row-is-the-job
  pattern).

  A `pending` row is work waiting for the scanner, `scanning` is in flight,
  and the resolved states record what happened: `approved` (released to the
  world), `rejected` (files deleted, owner notified — `category` says why),
  `canceled` (the subject disappeared before the verdict, e.g. a swept
  composer image or a deleted account). Resolved rows are kept: a rejection
  is the only surviving record of a deleted image, and the owner's
  notification feed derives from it.

  `fingerprint` binds the verdict to the exact scanned bytes for subjects
  that can change in place (a re-uploaded avatar, a re-captured screenshot):
  the claim queries compare it, so a stale verdict can never release bytes
  the model never saw. All fields are set programmatically by
  `Vutuv.Moderation.ImageScans` — there is no user-facing changeset.
  """

  use VutuvWeb, :model

  @kinds ~w(avatar cover post_image job_posting_image organization_image
            url_screenshot post_screenshot review_cover)
  @statuses ~w(pending scanning approved rejected canceled)
  @open_statuses ~w(pending scanning)

  schema "image_scans" do
    field(:kind, :string)
    field(:subject_id, Vutuv.UUIDv7)
    belongs_to(:owner, Vutuv.Accounts.User, foreign_key: :owner_user_id)

    field(:status, :string, default: "pending")
    field(:fingerprint, :string)
    field(:attempts, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime)
    field(:last_error, :string)
    field(:category, :string)
    field(:model, :string)
    field(:scanned_at, :utc_datetime)

    timestamps()
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  @doc "The statuses that count as unfinished work (mirrors the partial unique index)."
  def open_statuses, do: @open_statuses
end
