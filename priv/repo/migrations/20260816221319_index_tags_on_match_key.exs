defmodule Vutuv.Repo.Migrations.IndexTagsOnMatchKey do
  use Ecto.Migration

  # The match key (#1332) replaced two equality lookups that the unique indexes
  # on `tags.name` and `tags.slug` served with one expression no index covered,
  # so every tag lookup became a sequential scan of the catalog: 23 ms on a miss
  # over 8,632 rows, run five times per post save and once per keystroke of the
  # add-tag form. The expression is IMMUTABLE (lower, regexp_replace, btrim,
  # nullif), so it can be indexed as written; measured on a copy of the dev
  # catalog the same lookup drops to 0.2 ms.
  #
  # Keep the expression identical to `Vutuv.Tags.MatchKey.sql/1` — it is the
  # same key, and a drift here costs speed, not answers.
  # `test/vutuv/tags/match_key_index_test.exs` fails the build if the query can
  # no longer use these indexes.
  @name_key """
  nullif(btrim(regexp_replace(lower(regexp_replace(name, '[​‌‍﻿]', '', 'g')), '[[:space:]_-]+', '-', 'g'), '-'), '')\
  """

  @slug_key """
  nullif(btrim(regexp_replace(lower(regexp_replace(slug, '[​‌‍﻿]', '', 'g')), '[[:space:]_-]+', '-', 'g'), '-'), '')\
  """

  def up do
    create(index(:tags, ["(#{@name_key})"], name: :tags_name_match_key_index))
    create(index(:tags, ["(#{@slug_key})"], name: :tags_slug_match_key_index))

    # An expression index carries no statistics until the table is analyzed, and
    # without them the planner keeps choosing the sequential scan — the index is
    # there and unused until autovacuum next looks, which on a catalog that
    # rarely changes can be days.
    execute("ANALYZE tags")
  end

  def down do
    drop(index(:tags, [], name: :tags_slug_match_key_index))
    drop(index(:tags, [], name: :tags_name_match_key_index))
  end
end
