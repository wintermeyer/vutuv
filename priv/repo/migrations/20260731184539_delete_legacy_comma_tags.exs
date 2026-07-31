defmodule Vutuv.Repo.Migrations.DeleteLegacyCommaTags do
  use Ecto.Migration

  alias Vutuv.Tags

  # Deletes the legacy tags whose own name carries a comma — "Linux, Debian,
  # Ubuntu, CentOS, Red Hat", "suse,vmware,lxc,design,ubuntu". A comma is what
  # separates two tags when a member types a batch, so each of these is a pasted
  # list from before that rule: one row standing in for four or five topics,
  # found by none of them in a search, under a slug nobody would type.
  #
  # The work, and the reasoning for deleting rather than splitting them, lives
  # in Vutuv.Tags.delete_legacy_comma_tags/0 — where it is unit-tested against
  # real rows, which this migration cannot be: CI and `mix test` migrate an
  # empty database, so every row-touching line here would be dead code there.
  #
  # Data-only (no DDL), so it stays N-1 compatible for the blue/green deploy:
  # the currently deployed release keeps reading tags.name and the user_tags
  # pointing at them throughout, and simply finds fewer rows. The implicit
  # migration transaction makes the whole cleanup all-or-nothing.
  def up do
    summary =
      Tags.delete_legacy_comma_tags()
      |> Enum.reject(fn {_table, deleted} -> deleted == 0 end)
      |> Enum.sort()
      |> Enum.map_join(", ", fn {table, deleted} -> "#{deleted} #{table}" end)

    IO.puts("deleted #{summary}")
  end

  # The tags and every row that pointed at them are gone; there is nothing left
  # to reconstruct them from.
  def down, do: :ok
end
