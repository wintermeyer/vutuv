defmodule Vutuv.Repo.Migrations.DeleteOrphanedTags do
  use Ecto.Migration

  alias Vutuv.Tags

  # Removes the tag rows nothing points at any more. Runs straight after the
  # unconfirmed-registration cleanup because that is what creates most of them:
  # a tag whose only holders were abandoned sign-ups loses its last reference
  # when they go. The rest have been accumulating for years, from members who
  # dropped a tag again and from the tag cleanups that came before this one.
  #
  # "Nobody holds it" is deliberately not the test, and this is the part worth
  # reading twice. A tag with no holder can still be the chip under somebody's
  # post, the #hashtag in a sentence, a subscription, or the audience rule of a
  # newsletter group — deleting one of those would take a visible thing off
  # somebody else's page. The test is that no row in any table referencing tags
  # names it, read from the live foreign keys so a table added later counts too.
  # In the dev dry-run that distinction spared 129 rows that a plain
  # "no user_tags" rule would have deleted.
  #
  # The work is in Vutuv.Tags.delete_orphaned_tags/0, where it is unit-tested
  # against real rows for each of those kept cases; a migration cannot be tested
  # that way, since CI migrates an empty database.
  #
  # Data-only (no DDL) and N-1 compatible: the currently deployed release reads
  # the same tables and finds no reference to the deleted rows, because there was
  # none left to find.
  def up do
    deleted = Tags.delete_orphaned_tags() |> Map.get("tags", 0)

    IO.puts("deleted #{deleted} orphaned tag(s)")
  end

  # Re-deriving which names once existed is not possible; nothing referenced
  # them by the time they went.
  def down, do: :ok
end
