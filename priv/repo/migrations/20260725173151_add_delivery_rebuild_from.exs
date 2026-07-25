defmodule Vutuv.Repo.Migrations.AddDeliveryRebuildFrom do
  use Ecto.Migration

  # Lets a queued delivery re-render its activity at send time instead of
  # sending the copy built when it was enqueued.
  #
  # Why: a post's images are invisible until the AI scan releases them
  # (`Vutuv.Moderation.ImageScans`), so a Create built at commit time carries no
  # attachment and the picture never reaches the other network. Such a post is
  # now enqueued with a short hold and this marker; the deliverer rebuilds the
  # Note when the hold expires, or earlier when the scan settles and pulls the
  # row forward.
  #
  # `activity_json` deliberately stays NOT NULL and keeps holding a complete,
  # valid activity. A release that does not know this column simply sends that
  # copy, so the worst a deploy window can do is federate one post without its
  # picture, never crash on a half-built row.
  def change do
    alter table(:fediverse_deliveries) do
      add(:rebuild_from, :string)
    end
  end
end
