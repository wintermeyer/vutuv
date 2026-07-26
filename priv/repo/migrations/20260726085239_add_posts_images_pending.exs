defmodule Vutuv.Repo.Migrations.AddPostsImagesPending do
  @moduledoc """
  A post waits for **all** of its photos to clear the AI image scan before it
  becomes public (issue #1104 follow-up).

  This is a **denormalised** flag rather than a `NOT EXISTS` over `post_images`
  in the visibility scope, because that scope is the newsfeed's inner loop: it
  runs for every candidate row of every feed page. `Vutuv.Posts` recomputes the
  column at the three moments it can change (a post is created, edited, or one
  of its scans settles), so the read path stays a plain boolean test.

  Existing posts are `false` — they are already public, and nothing about them
  changes.

  N-1 safe: a plain addition with a default. The previous release simply does
  not read it, so during the switch window it keeps showing posts the new
  release would hold back. That is the old behaviour, not a regression, and it
  lasts only until nginx flips.
  """

  use Ecto.Migration

  def change do
    alter table(:posts) do
      add(:images_pending?, :boolean, null: false, default: false)
    end

    # The visibility scope's condition, and the sweeper's "what is still
    # waiting" query. Partial, because the `true` rows are a handful at any
    # moment while the `false` rows are the whole table.
    create(index(:posts, [:images_pending?], where: "\"images_pending?\" = true"))
  end
end
