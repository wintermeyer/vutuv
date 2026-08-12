defmodule Vutuv.Repo.Migrations.EnforceTagSlugActorGrammar do
  @moduledoc """
  The constraint that keeps tag slugs inside the actor grammar (issue #1332,
  the last piece): a live tag's slug is `^[a-z0-9_]+$`, so it is usable as the
  name of that tag's fediverse actor with no mapping in between (#1330).

  **An alias is exempt, and that is the point of it.** A `former` row exists to
  keep the spelling a topic used to have reachable (`/tags/<old>` answers 301),
  so it must be allowed to hold exactly the shape this constraint forbids.

  ## Why this waited for its own deploy

  Deploys here are blue/green: the migration runs while the **previous** release
  is still serving. Until v7.276.0 was live, that release's slugifier still
  wrote hyphens, so a tag minted in the switch window would have violated this
  constraint and 500ed. v7.276.0 reached production before this shipped, and its
  slugifier writes nothing else, so there is no window left.

  Guarded on the application side too (`Vutuv.Tags.Tag`): the changeset
  validates the same shape and names this constraint, so an admin editing a slug
  by hand gets a field error rather than a crash.
  """
  use Ecto.Migration

  @check :tags_slug_actor_grammar

  def up do
    create(
      constraint(:tags, @check,
        check: "merged_into_id IS NOT NULL OR slug ~ '^[a-z0-9_]+$'"
      )
    )
  end

  def down do
    drop(constraint(:tags, @check))
  end
end
