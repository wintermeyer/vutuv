defmodule Vutuv.Repo.Migrations.FixMastodonMarkerPageUniqueness do
  use Ecto.Migration

  @moduledoc """
  A page's reading position is one row, and the index has to say so.

  `mastodon_markers` shipped one migration ago (v7.322.0) with the page's
  uniqueness spread over `(user_id, organization_id, timeline)`, while every
  read in `Vutuv.MastodonApi.Markers` is scoped to `organization_id` alone —
  the position belongs to the page, not to whichever publisher looked at it.
  An index narrower than the invariant its queries assume permits exactly what
  they cannot survive: two publishers writing in the same instant each insert
  their own row, and from then on the `Repo.one/1` behind every read raises
  `Ecto.MultipleResultsError`. Not a slow path — a 500 on that page's markers,
  for good, because nothing ever removes the second row.

  So the index loses `user_id`. The column stays: it still records which
  publisher's client first stored a position, which is worth having and is no
  longer part of what makes the row unique.

  **The fold comes first**, because a duplicate may already exist by the time
  this runs and `CREATE UNIQUE INDEX` would refuse it — leaving the table with
  no page-level uniqueness at all, which is worse than what it replaces. The
  newest row per page and timeline wins: these are bookmarks, and the most
  recently written one is the position a client last reported.

  N-1 compatible. The running release neither reads nor writes through the old
  index (it finds the page's row by `organization_id` and updates it), so the
  only behaviour it can newly meet is the collision it already raised on.
  """

  def up do
    execute("""
    DELETE FROM mastodon_markers m
    USING mastodon_markers keep
    WHERE m.organization_id IS NOT NULL
      AND m.organization_id = keep.organization_id
      AND m.timeline = keep.timeline
      AND (keep.updated_at, keep.id) > (m.updated_at, m.id)
    """)

    drop(index(:mastodon_markers, [:user_id, :organization_id, :timeline], name: :mastodon_markers_organization_timeline_index))

    create(
      unique_index(:mastodon_markers, [:organization_id, :timeline],
        where: "organization_id IS NOT NULL",
        name: :mastodon_markers_organization_timeline_index
      )
    )
  end

  def down do
    drop(index(:mastodon_markers, [:organization_id, :timeline], name: :mastodon_markers_organization_timeline_index))

    create(
      unique_index(:mastodon_markers, [:user_id, :organization_id, :timeline],
        where: "organization_id IS NOT NULL",
        name: :mastodon_markers_organization_timeline_index
      )
    )
  end
end
