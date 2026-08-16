defmodule Vutuv.Repo.Migrations.FixHashtagPrefixedTagNames do
  use Ecto.Migration

  @moduledoc """
  Takes the leading `#` off the tag names that still carry one.

  A `#` belongs to the hashtag *notation*, never to the tag: `#phoenix` is not a
  second topic beside `phoenix`, it is `phoenix` stored wrong. The catalog
  collected such rows until the tag input learned to strip the prefix (the
  newest on vutuv.de is from 2026-07-01); this migration corrects the rows that
  are already there, and `Vutuv.Tags.Tag` now refuses a new one.

  ## Two steps, because a rename is not always enough

  **1. Strip the prefix.** Generic, over whatever the installation happens to
  hold: every name that opens with a `#` loses the whole opening run of `#` and
  the whitespace between them, and interior whitespace collapses — the same
  thing `Vutuv.Tags.Tag.normalize_value/1` does to a typed value, written once
  in SQL. Slugs are left alone: the slugifier already dropped the `#` when the
  row was minted, so `#3DPrinting` sits on `/tags/3dprinting` and no URL moves.
  A name that is nothing *but* `#` would strip to blank and is skipped rather
  than emptied — there is no such row on vutuv.de, and a blank name is worse
  than a wrong one.

  **2. Fold the six rows that are now a second copy of an existing tag.** Where
  the `#` had pushed the slugifier onto a suffixed slug (`phoenix_c088bedb`,
  because `phoenix` was taken), stripping the name leaves two rows for one
  topic. Those are listed below by slug and folded through
  `Vutuv.Tags.Merge.merge/3` — the same code path the admin screen uses, so the
  members, posts, follows, job postings, cached remote posts and newsletter
  audiences move with the endorsement rescue, and every fold lands on
  `/admin/tag_merges` where it can be taken back one at a time.

  Step 1 has to run **first**: `Merge` refuses a pair whose names differ only in
  characters the slugifier deletes (the `c` / `c++` / `c#` guard from #1337),
  and `#phoenix` against `phoenix` is exactly that shape until the `#` is gone.

  ## Which row survives a fold

  The one whose slug has no `_<sha>` suffix, because that slug is the public URL
  and the tag's fediverse actor name. On five of the six pairs that row is also
  the one with far more profiles, so nothing is lost. The sixth is
  `myelixirstatus`, where the `#` row is the *older* one and holds the clean
  slug: it survives (with its name corrected in step 1) and the suffixed row
  folds into it, so `/tags/myelixirstatus` keeps working.

  A former-slug alias is re-pointed at the survivor before the fold, so no
  alternative name ends up pointing at another alternative name — `Tag` resolves
  exactly one hop.

  ## Elsewhere, and on the way back

  Every fold names **slugs**, matched exactly, so a pair that is absent is
  skipped and a fresh database — CI, `mix test`, another installation — folds
  nothing. Step 1 stays generic and corrects whatever that installation has.

  N-1 safe: no schema change. The deployed release reads `tags.name` and already
  resolves an alias to its topic.

  `down/0` reverts the folds it made. Two things it deliberately leaves: the
  `#` stays off (the prefix was the bug, and which rows carried it is not
  recoverable from the rows themselves once it is gone), and a re-pointed
  former-slug alias keeps pointing at the survivor — which is where it belongs
  either way, since both rows name the one topic.
  """

  # {surviving slug, absorbed slug}. Read off vutuv.de's catalog by hand; the
  # comment is the state each pair was read in, as name (profiles carrying it).
  @folds [
    # phoenix (18) <- #phoenix (1)
    {"phoenix", "phoenix_c088bedb"},
    # haskell (13) <- #haskell (1)
    {"haskell", "haskell_014b6157"},
    # innovation (13) <- #Innovation (1)
    {"innovation", "innovation_45d06e1c"},
    # Grafana (3) <- #Grafana (0, one post)
    {"grafana", "grafana_5dbba8ec"},
    # Observability (3) <- #Observability (0, one post)
    {"observability", "observability_a23c7928"},
    # #myelixirstatus (1) <- myelixirstatus (1). The only pair where the `#` row
    # survives: it is the older of the two and it holds the unsuffixed slug.
    {"myelixirstatus", "myelixirstatus_5c46085c"}
  ]

  @merge_module Vutuv.Tags.Merge
  @tag_module Vutuv.Tags.Tag

  # `#`, the whitespace between a run of them, and the run itself — anchored at
  # the start, so `C#`, `F#` and `fitness#stuff` keep the `#` they earned.
  @strip_prefix "^[[:space:]#]*#"
  @has_prefix "^[[:space:]]*#"

  @doc """
  The folds this migration performs, as `{surviving slug, absorbed slug}`.
  Public so the test asserts against this list rather than a copy of it.
  """
  def folds, do: @folds

  def up do
    IO.puts("fix_hashtag_prefixed_tag_names: " <> strip_prefixes(repo()))
    IO.puts("fix_hashtag_prefixed_tag_names: " <> fold_duplicates(repo()))
  end

  def down, do: IO.puts("fix_hashtag_prefixed_tag_names: " <> revert_folds(repo()))

  @doc """
  Step 1 against an explicit repo, returning the report as a line.

  Public and repo-taking so the test drives **this** code rather than a copy of
  it: `repo/0` only answers inside a running migration.
  """
  def strip_prefixes(repo) do
    %{num_rows: renamed} =
      repo.query!("""
      update tags
         set name = btrim(regexp_replace(regexp_replace(name, '#{@strip_prefix}', ''), '[[:space:]]+', ' ', 'g')),
             updated_at = timezone('utc', now())
       where name ~ '#{@has_prefix}'
         and regexp_replace(name, '#{@strip_prefix}', '') ~ '[^[:space:]]'
      """)

    %{rows: [[left]]} =
      repo.query!("select count(*) from tags where name ~ '#{@has_prefix}'")

    "#{renamed} names corrected, #{left} left alone (nothing but hashes)"
  end

  @doc "Step 2 against an explicit repo. See `strip_prefixes/1`."
  def fold_duplicates(repo) do
    if available?() do
      report = Enum.reduce(@folds, %{folded: 0, missing: 0, failed: [], repo: repo}, &fold/2)

      "#{report.folded} duplicates folded" <>
        ", #{report.missing} listed pairs not present here" <>
        ", #{length(report.failed)} refused#{failures(report.failed)}"
    else
      "#{inspect(@merge_module)} is unavailable, nothing folded"
    end
  end

  @doc """
  Reverts every fold this migration made and nobody has undone by hand.

  Recognised by having no admin behind it: a merge from the admin screen always
  records who did it, this one cannot. A fold already reverted stays reverted.
  """
  def revert_folds(repo) do
    if available?() do
      reverted =
        @folds
        |> Enum.map(fn {_keeper, absorbed} -> repo.get_by(@tag_module, slug: absorbed) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.flat_map(&merges_of(repo, &1))
        |> Enum.count(fn merge -> match?({:ok, _}, @merge_module.revert(merge)) end)

      "#{reverted} folds reverted, names left corrected"
    else
      "#{inspect(@merge_module)} is unavailable, nothing reverted"
    end
  end

  defp fold({keeper_slug, absorbed_slug}, acc) do
    keeper = acc.repo.get_by(@tag_module, slug: keeper_slug)
    absorbed = acc.repo.get_by(@tag_module, slug: absorbed_slug)

    if is_nil(keeper) or is_nil(absorbed) do
      %{acc | missing: acc.missing + 1}
    else
      repoint_aliases(acc.repo, absorbed, keeper)

      case @merge_module.merge(absorbed, keeper, kind: "former") do
        {:ok, _merge} -> %{acc | folded: acc.folded + 1}
        {:error, why} -> %{acc | failed: acc.failed ++ [{absorbed_slug, why}]}
      end
    end
  end

  # An alternative name filed under the row about to be absorbed — the retired
  # dotted slug `phoenix.c088bedb`, say — has to move to the survivor first:
  # `Vutuv.Tags.Tag.find_by_value/1` follows exactly one hop, so an alias left
  # pointing at an alias resolves to a row no listing shows.
  defp repoint_aliases(repo, absorbed, keeper) do
    repo.query!(
      "update tags set merged_into_id = $1::text::uuid where merged_into_id = $2::text::uuid",
      [keeper.id, absorbed.id]
    )
  end

  # The unreverted merges recorded for this absorbed tag that no admin performed.
  defp merges_of(repo, tag) do
    import Ecto.Query

    repo.all(
      from(m in "tag_merges",
        where:
          m.absorbed_tag_id == type(^tag.id, Vutuv.UUIDv7) and is_nil(m.reverted_at) and
            is_nil(m.admin_user_id),
        select: m.id
      )
    )
    |> Enum.map(&@merge_module.get_merge(Ecto.UUID.cast!(&1)))
    |> Enum.reject(&is_nil/1)
  end

  # A migration must stay replayable long after the code around it has moved on,
  # so the one app module it leans on is checked rather than assumed.
  defp available? do
    Code.ensure_loaded?(@merge_module) and function_exported?(@merge_module, :merge, 3)
  end

  defp failures([]), do: ""

  defp failures(failed) do
    " (" <> Enum.map_join(failed, ", ", fn {slug, why} -> "#{slug}: #{why}" end) <> ")"
  end
end
