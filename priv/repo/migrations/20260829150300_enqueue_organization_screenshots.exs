defmodule Vutuv.Repo.Migrations.EnqueueOrganizationScreenshots do
  use Ecto.Migration

  import Ecto.Query

  # Queues a homepage capture for every organization that already names a
  # website. New pages enqueue themselves from
  # `Vutuv.Organizations.Screenshots.reconcile/1`; the pages that existed before
  # this feature have nothing that would ever call it, so they are enqueued once
  # here. No capture happens in the migration itself — a deploy must not wait on
  # headless Chromium, and the job rows are exactly what
  # `Vutuv.Organizations.ScreenshotWorker` drains afterwards, a few at a time.
  #
  # Archived pages are left out: nobody can reach one, so a capture would be a
  # browser run spent on a page that is never rendered.
  def up do
    now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

    rows =
      from(o in "organizations",
        where: not is_nil(o.website_url) and o.website_url != "" and o.status != "archived",
        select: %{id: o.id, url: o.website_url}
      )
      |> repo().all()
      |> Enum.map(
        &%{
          # A raw table name carries no field types, so the id is dumped to the
          # 16 bytes the uuid column wants rather than handed over as text.
          id: Ecto.UUID.dump!(Vutuv.UUIDv7.generate()),
          organization_id: &1.id,
          url: &1.url,
          status: "pending",
          attempts: 0,
          inserted_at: now,
          updated_at: now
        }
      )

    # `on_conflict: :nothing` against the unique organization_id index, so a
    # re-run — or a page that enqueued itself between the two migrations —
    # leaves the existing job alone instead of failing the deploy.
    repo().insert_all("organization_screenshots", rows, on_conflict: :nothing)
  end

  def down do
    repo().delete_all(from(s in "organization_screenshots", where: s.status == "pending"))
  end
end
