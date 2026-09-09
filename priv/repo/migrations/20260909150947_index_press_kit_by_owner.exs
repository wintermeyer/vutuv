defmodule Vutuv.Repo.Migrations.IndexPressKitByOwner do
  @moduledoc """
  A partial index for the press-kit shelves (issue #2086).

  #2083 measured this and decided against it, correctly for the callers it had:
  `images_user_id_index` already answers "this member's pictures", and the
  busiest member on the production copy owns 60 of them, average 5.8 — so
  filtering `kind = 'press_kit'` in the heap cost almost nothing while the only
  readers were `/settings/press` and the proxy.

  #2086 moves that read onto **every profile mount** and every profile agent
  document, which is the hottest page on the site, and adds a table-wide one for
  the sitemap (`Vutuv.Sitemap.press_entries/1`), which had no index to stand on
  at all and could only seq-scan a table that holds every picture on the
  installation. The partial index makes both index-only: `user_id` leads it for
  the per-member shelf, and the whole index *is* the press-kit rows for the
  sitemap's owner-id list. `logo` and `position` ride along because they are
  what a shelf is split and ordered by, so a shelf read never touches the heap.

  Measured on a padded copy of `images` — 60,000 post photos over 1,000 members
  plus a press kit of eight for fifty of them, which is the shape the production
  table already has:

    * one member's shelf: 1.81 ms / 1,162 buffers → **0.020 ms / 12 buffers**
      (the bitmap scan over that member's 68 pictures becomes an index scan over
      their 8);
    * the sitemap's owner list: 3.05 ms / 1,099 buffers, a full sequential scan
      of the table → **0.043 ms / 12 buffers**.

  Additive, so N-1 compatible on its own; `CONCURRENTLY` is deliberately not
  used, because the matching rows number in the dozens today and a migration
  outside a transaction costs more than the lock it avoids.
  """
  use Ecto.Migration

  def change do
    create(
      index(:images, [:user_id, :logo, :position],
        where: "kind = 'press_kit'",
        name: :images_press_kit_user_index
      )
    )

    # Its twin for a page's kit (#2087), added here so the two owner sides of
    # the same nullable pair cannot get one index and not the other.
    create(
      index(:images, [:organization_id, :logo, :position],
        where: "kind = 'press_kit'",
        name: :images_press_kit_organization_index
      )
    )
  end
end
