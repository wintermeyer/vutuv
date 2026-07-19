defmodule Mix.Tasks.Vutuv.Moderation.Backfill do
  @moduledoc """
  Queues AI image scans for the images that were **grandfathered** as
  approved when image moderation shipped (and for anything else currently
  released): every avatar, cover, post / job-posting / organization image and
  link screenshot gets an `image_scans` row, which the regular
  `Vutuv.Moderation.ImageScanWorker` then drains at its own pace.

  Deliberately non-disruptive: nothing is hidden while it waits — an already
  visible image stays visible until its verdict, and only an *unsafe* verdict
  changes anything (files deleted, owner notified — the same treatment a
  fresh upload gets). Safe verdicts are no-ops. Idempotent: the partial
  unique index means re-running just tops up missing queue rows.

      mix vutuv.moderation.backfill

  Requires `:moderate_images` to be enabled (otherwise enqueue is a no-op).
  """

  use Mix.Task

  import Ecto.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Jobs.JobPostingImage
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Organizations.OrganizationImage
  alias Vutuv.Posts.PostImage
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Profiles.Url
  alias Vutuv.Repo

  @shortdoc "Queues AI image scans for the grandfathered image catalog"

  def run(_args) do
    Mix.Task.run("app.start", [])

    unless ImageScans.enabled?() do
      Mix.raise("AI image moderation is disabled (:moderate_images) — nothing to backfill.")
    end

    for {label, rows} <- sources() do
      count =
        rows
        |> Enum.map(fn {kind, subject_id, owner_id, fingerprint} ->
          ImageScans.enqueue(kind, subject_id, owner_id, fingerprint)
        end)
        |> length()

      IO.puts("#{label}: queued #{count} scan(s)")
    end

    IO.puts("Done. The image scan worker drains the queue in the background.")
  end

  defp sources do
    [
      {"avatars",
       Repo.all(
         from(u in User,
           where: not is_nil(u.avatar),
           select: {"avatar", u.id, u.id, u.avatar_fingerprint}
         )
       )},
      {"covers",
       Repo.all(
         from(u in User,
           where: not is_nil(u.cover_photo),
           select: {"cover", u.id, u.id, u.cover_fingerprint}
         )
       )},
      {"post images",
       Repo.all(from(i in PostImage, select: {"post_image", i.id, i.user_id, nil}))},
      {"job posting images",
       Repo.all(from(i in JobPostingImage, select: {"job_posting_image", i.id, i.user_id, nil}))},
      {"organization images",
       Repo.all(
         from(i in OrganizationImage, select: {"organization_image", i.id, i.user_id, nil})
       )},
      {"link screenshots",
       Repo.all(
         from(u in Url,
           where: not is_nil(u.screenshot),
           select: {"url_screenshot", u.id, u.user_id, u.screenshot}
         )
       )},
      {"post link screenshots",
       Repo.all(
         from(ps in PostScreenshot,
           join: p in assoc(ps, :post),
           where: ps.status == "ready" and not is_nil(ps.screenshot),
           select: {"post_screenshot", ps.id, p.user_id, ps.screenshot}
         )
       )}
    ]
  end
end
