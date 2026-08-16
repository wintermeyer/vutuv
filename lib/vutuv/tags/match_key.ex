defmodule Vutuv.Tags.MatchKey do
  @moduledoc """
  The one key two spellings of a topic have to agree on (issue #1332).

  A tag used to be looked up by its exact lowercased name or its exact slug,
  which let space and hyphen resolve **by accident** — the slugifier writes
  hyphens and the slug is one of the two keys — while underscore against
  anything did not, in either direction. Underscores are the shape the older
  half of the catalog carries, so every such lookup missed the tag that already
  existed and minted a second page for it: exactly the sprawl #1338's merge pass
  had just cleaned up by hand.

  The key case-folds, drops zero-width characters and collapses a run of
  space / hyphen / underscore to a single `-`.

  Four rules, each from a real row in the catalog:

  - **Collapse, never delete.** `Open-Source Software` and `open source
    software` are one topic. `e commerce` against `ecommerce` is a judgement
    call and stays two names for a human to merge.
  - **Strip zero-width characters** before comparing. Two names in the catalog
    differ only by a U+200B: invisible to every reader, distinct to Postgres.
  - **A key with nothing to key on is no key.** A value with no `[a-z0-9]` left
    (`-`, `.`) answers `nil` and matches nothing, rather than bucketing every
    such name into one topic.
  - **Punctuation that carries meaning is kept.** `c++` keys as `c++`, not as
    `c` — the distinction between C, C++ and C# is the subject of #1337 and must
    survive the lookup, not be folded away by it.

  Both sides of the comparison live here, in Elixir for the typed value and as
  a Postgres expression for the stored column, so they cannot drift apart.
  """

  # U+200B ZERO WIDTH SPACE, U+200C ZWNJ, U+200D ZWJ, U+FEFF BOM.
  @zero_width ~r/[\x{200B}\x{200C}\x{200D}\x{FEFF}]/u
  @separators ~r/[\s_-]+/u
  @keyable ~r/[a-z0-9]/u

  @doc """
  The key for a typed value, or `nil` when there is nothing to match on.

      iex> Vutuv.Tags.MatchKey.normalize("Open__Source - Software")
      "open-source-software"

      iex> Vutuv.Tags.MatchKey.normalize("-")
      nil
  """
  def normalize(value) when is_binary(value) do
    key =
      value
      |> String.replace(@zero_width, "")
      |> String.downcase()
      |> String.replace(@separators, "-")
      |> String.trim("-")

    if Regex.match?(@keyable, key), do: key
  end

  def normalize(_), do: nil

  @doc """
  The same key over a stored column, as a Postgres expression.

  Written as one fragment rather than composed, because Ecto needs the SQL
  literal at the call site; both callers (`Vutuv.Tags.Tag.find_by_value/1` and
  `Vutuv.Tags.canonical_tag_names/1`) get it from here so there is one
  definition of the key and not three.

  `tags_name_match_key_index` and `tags_slug_match_key_index` index exactly this
  expression, so a lookup is a bitmap index scan rather than a walk of the
  catalog. Postgres matches an expression index by the parsed expression: change
  a character here and every tag lookup quietly goes back to a sequential scan,
  which is what `test/vutuv/tags/match_key_index_test.exs` watches for.

  Verified against the real catalog rather than read off the code: it folds
  `Open__Source - Software`, `open-source-software` and `legacy_framework_zzz`
  onto the keys their siblings carry, strips a U+200B, answers NULL for `-`,
  and leaves `c++` and non-ASCII names alone.
  """
  defmacro sql(column) do
    quote do
      fragment(
        """
        nullif(
          btrim(
            regexp_replace(
              lower(regexp_replace(?, '[​‌‍﻿]', '', 'g')),
              '[[:space:]_-]+', '-', 'g'
            ),
            '-'
          ),
          ''
        )\
        """,
        unquote(column)
      )
    end
  end
end
