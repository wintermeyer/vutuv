defmodule Vutuv.Repo.Migrations.DeleteLegacyOverlongTags do
  use Ecto.Migration

  alias Vutuv.Tags

  # Deletes the legacy tags whose name runs to 35 characters or more. Past that
  # length a name stops being a topic and starts being a sentence lifted out of
  # a job ad — and 140 of them end in a literal "..." at exactly 40 characters,
  # where a legacy importer truncated them mid-word. Neither names anything a
  # reader could search for or type.
  #
  # Runs after the comma cleanup, which has already taken the pasted lists, so
  # the two sets barely overlap by the time this executes. The work and the
  # reasoning live in Vutuv.Tags.delete_legacy_overlong_tags/0, where they are
  # unit-tested against real rows — including the 34/35 boundary and a German
  # name whose umlauts make it longer in bytes than in characters. This
  # migration cannot be tested that way: CI and `mix test` migrate an empty
  # database, so every row-touching line here would be dead code there.
  #
  # Data-only (no DDL), so it stays N-1 compatible for the blue/green deploy:
  # the currently deployed release keeps reading tags.name and the user_tags
  # pointing at them throughout, and simply finds fewer rows. The implicit
  # migration transaction makes the whole cleanup all-or-nothing.
  def up do
    summary =
      Tags.delete_legacy_overlong_tags()
      |> Enum.reject(fn {_table, deleted} -> deleted == 0 end)
      |> Enum.sort()
      |> Enum.map_join(", ", fn {table, deleted} -> "#{deleted} #{table}" end)

    IO.puts("deleted #{summary}")
  end

  # The tags and every row that pointed at them are gone; there is nothing left
  # to reconstruct them from.
  def down, do: :ok
end
