defmodule Vutuv.Repo.Migrations.BackfillFeedSourceAt do
  use Ecto.Migration

  @moduledoc """
  Gives every member who already chose a feed source tab an anchor for the
  unseen dot (`VutuvWeb.PostLive.Feed.unseen_at_mount/3`).

  The dot on the tab you are not on is derived at each mount from
  `feed_source_at` — the last moment that tab was on screen. The column landed
  one release ago and is written only when a tab is pressed, so nearly every
  member who chose one months back has a NULL there and would get no dot until
  they happened to press a tab again. `NOW()` reads as "everything up to the
  deploy counts as seen", which is the conservative half: it withholds a dot,
  it never invents one. Members still on "All" keep their NULL — they see both
  halves, so nothing can land elsewhere.

  N-1 safe: the previous release reads the column too, and a later stamp only
  makes it show fewer dots.
  """

  def up do
    execute("""
    UPDATE users
       SET feed_source_at = (NOW() AT TIME ZONE 'utc')
     WHERE feed_source IS NOT NULL
       AND feed_source_at IS NULL
    """)
  end

  # Nothing to undo: the column's own migration drops it.
  def down, do: :ok
end
