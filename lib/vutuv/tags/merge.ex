defmodule Vutuv.Tags.Merge do
  @moduledoc """
  Folding one topic's several tags into one page (issue #1338).

  `Ruby on Rails`, `rails`, `ROR` and `rubyonrails` are four pages for one
  subject. Absorbing one into another moves every row filed under it — the tag
  on a member's profile and the vouches under it, the posts, the follows, the
  job postings, a cached post from another network, a newsletter audience — and
  then files the absorbed tag as an **alternative name** rather than deleting
  it. Keeping that row is what lets its slug go on resolving and what makes the
  whole act reversible.

  Three things are deliberate:

    * **Nothing is deleted that can be moved.** Only a row whose owner already
      holds the surviving tag has to go, because of the `(owner, tag)` unique
      index — a member carrying both spellings ends up carrying the topic once.
      Their endorsements move onto the surviving row first, so a vouch somebody
      gave is not collateral damage.
    * **Every merge can be taken back.** `merge/3` writes what it did into
      `Vutuv.Tags.TagMerge`: the ids it moved and the full content of the rows
      it had to drop. `revert/1` moves the ids back and re-inserts the dropped
      rows verbatim — same ids, so anything that pointed at them still does.
    * **The dangerous cases are refused by rule, not by judgement.** An honor
      tag never merges, an alias never merges again, a pair a human called
      distinct stays distinct, and a pair whose names differ only in characters
      the slugifier deletes is refused outright — that is the `c` / `c++` /
      `c#` / `µc` bucket from #1337, four languages one normalization would
      happily fold into one.

  The row-moving is written in SQL rather than in Ecto because a revert has to
  restore a **row**, not a schema's idea of one: `to_jsonb(t)` captures it whole
  and `jsonb_populate_record` puts it back, with no per-column knowledge here
  that could fall out of step with a future migration. Table and column names
  come from the compile-time list `@movable`, never from anything a caller
  supplies. Ids are passed as text and cast (`$1::text::uuid`), the form
  Postgrex can encode.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Vutuv.Repo
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.TagDistinction
  alias Vutuv.Tags.TagMerge

  # Every table with a `tag_id`, and the column that makes a row's owner unique
  # under it (`nil` where a tag can be filed twice, so nothing ever collides).
  # A new table pointing at `tags` belongs here, or a merge would leave its rows
  # behind on a tag that is no longer a topic.
  @movable [
    {"user_tags", "user_id"},
    {"post_tags", "post_id"},
    {"post_hashtags", "post_id"},
    {"tag_follows", "user_id"},
    {"job_posting_tags", "job_posting_id"},
    {"fediverse_post_tags", "remote_post_id"},
    {"newsletter_groups", nil}
  ]

  @doc """
  What a merge would do, without doing any of it: `%{moved: %{table => count},
  dropped: %{table => count}}`, or `{:error, reason}` when the merge is refused.

  The split matters to whoever confirms it — a moved row keeps a member's
  profile as it was, a dropped one means somebody carried both spellings.
  """
  def preview(%Tag{} = absorbed, %Tag{} = canonical) do
    with :ok <- check(absorbed, canonical) do
      counts = count_move(List.wrap(absorbed.id), canonical)
      Map.merge(counts, %{absorbed: absorbed, canonical: canonical})
    end
  end

  @doc """
  The same, for absorbing **several** tags into one — the way a topic is
  actually tidied up, since `Ruby on Rails` is spread over four spellings and
  not two.

  Answers `%{moved:, dropped:, mergeable: [tag], refused: [{tag, reason}]}`: a
  tag the merge would refuse is named with its reason rather than silently
  dropped from the list, and the others can still go ahead.

  The counts are the ones the sequence really produces, not the sum of the
  pairs. Merging `A` and `B` into `C` for a member who holds `A` and `B` but not
  `C` moves one row and drops the other, because by the time `B` is absorbed
  that member already carries `C` — adding two separate previews would promise
  two moves.
  """
  def preview_many(absorbed, %Tag{} = canonical) when is_list(absorbed) do
    checked = Enum.map(absorbed, fn tag -> {tag, check(tag, canonical)} end)
    mergeable = for {tag, :ok} <- checked, do: tag
    refused = for {tag, {:error, reason}} <- checked, do: {tag, reason}

    counts =
      case mergeable do
        [] -> %{moved: %{}, dropped: %{}}
        tags -> count_move(Enum.map(tags, & &1.id), canonical)
      end

    Map.merge(counts, %{
      mergeable: mergeable,
      refused: refused,
      canonical: canonical
    })
  end

  # Per table: how many rows move and how many are dropped as duplicates when
  # `absorbed_ids` are absorbed into `canonical`. One row per owner survives —
  # the rest collide on the `(owner, tag)` unique index — which is what the
  # window function counts, so the answer holds for one absorbed tag and for
  # five.
  defp count_move(absorbed_ids, canonical) do
    Enum.reduce(@movable, %{moved: %{}, dropped: %{}}, fn {table, owner}, acc ->
      %{rows: [[moved, dropped]]} =
        Repo.query!(move_counts_sql(table, owner), [absorbed_ids, canonical.id])

      acc
      |> put_count(:moved, table, moved)
      |> put_count(:dropped, table, dropped)
    end)
  end

  # A table with no owner column cannot collide: every row simply moves.
  defp move_counts_sql(table, nil) do
    """
    select count(*), 0
    from #{table}
    where tag_id = any($1::text[]::uuid[]) and $2::text::uuid is not null
    """
  end

  defp move_counts_sql(table, owner) do
    """
    select
      count(*) filter (where rn = 1 and not held),
      count(*) filter (where rn > 1 or held)
    from (
      select
        row_number() over (partition by a.#{owner} order by a.id) as rn,
        exists (
          select 1 from #{table} b
          where b.tag_id = $2::text::uuid and b.#{owner} = a.#{owner}
        ) as held
      from #{table} a
      where a.tag_id = any($1::text[]::uuid[])
    ) rows
    """
  end

  @doc """
  Absorbs several tags into one, each as its own recorded merge so each can be
  taken back on its own.

  Answers `%{merged: [%TagMerge{}], failed: [{tag, reason}]}`. A refusal stops
  that one tag, not the rest: the reviewer has already decided the others belong
  together, and making them start over because one entry was an honor tag would
  be the wrong lesson to teach.
  """
  def merge_all(absorbed, %Tag{} = canonical, opts \\ []) when is_list(absorbed) do
    Enum.reduce(absorbed, %{merged: [], failed: []}, fn tag, acc ->
      case merge(tag, canonical, opts) do
        {:ok, merge} -> Map.update!(acc, :merged, &(&1 ++ [merge]))
        {:error, reason} -> Map.update!(acc, :failed, &(&1 ++ [{tag, reason}]))
      end
    end)
  end

  @doc """
  Absorbs `absorbed` into `canonical` in one transaction and records it.

  `opts` takes `:actor` (the admin) and `:kind` (the alias kind the absorbed
  name is filed under, `"former"` by default — it *was* the tag's own name).
  Returns `{:ok, %TagMerge{}}` or `{:error, reason}`.
  """
  def merge(%Tag{} = absorbed, %Tag{} = canonical, opts \\ []) do
    kind = Keyword.get(opts, :kind, "former")
    actor = Keyword.get(opts, :actor)

    with :ok <- check(absorbed, canonical) do
      Multi.new()
      |> Multi.run(:rows, fn repo, _ -> {:ok, move_rows(repo, absorbed, canonical)} end)
      |> Multi.update(:alias, Tag.alias_changeset(absorbed, canonical, kind))
      |> Multi.insert(:merge, fn %{rows: rows} ->
        TagMerge.changeset(%TagMerge{}, %{
          canonical_tag_id: canonical.id,
          absorbed_tag_id: absorbed.id,
          admin_user_id: actor && actor.id,
          moved_counts: rows.counts,
          undo: %{"moves" => rows.moves, "deletes" => rows.deletes}
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{merge: merge}} -> {:ok, merge}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  @doc """
  Takes a merge back: every moved row returns to the absorbed tag, every dropped
  row is re-inserted as it was, and the absorbed tag stops being an alias.

  A merge is reverted once; a second attempt answers `{:error, :already_reverted}`.
  """
  def revert(%TagMerge{reverted_at: %NaiveDateTime{}}), do: {:error, :already_reverted}

  def revert(%TagMerge{} = merge) do
    absorbed = Repo.get!(Tag, merge.absorbed_tag_id)

    Multi.new()
    |> Multi.run(:restore, fn repo, _ -> {:ok, restore(repo, merge.undo)} end)
    |> Multi.update(:alias, Ecto.Changeset.change(absorbed, merged_into_id: nil, alias_kind: nil))
    |> Multi.update(:merge, Ecto.Changeset.change(merge, reverted_at: now()))
    |> Repo.transaction()
    |> case do
      {:ok, %{merge: merge}} -> {:ok, merge}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Records that these two tags are different topics, so no assisted pass proposes
  the pair again and no merge of it goes through by hand either.

  Saying it twice is not an error: the second call answers with the row already
  there.
  """
  def mark_distinct(%Tag{} = a, %Tag{} = b, opts \\ []) do
    {tag_a_id, tag_b_id} = TagDistinction.ordered(a, b)
    actor = Keyword.get(opts, :actor)

    %TagDistinction{}
    |> TagDistinction.changeset(%{
      tag_a_id: tag_a_id,
      tag_b_id: tag_b_id,
      admin_user_id: actor && actor.id
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:tag_a_id, :tag_b_id])
    |> case do
      {:ok, %TagDistinction{id: nil}} -> {:ok, get_distinction(tag_a_id, tag_b_id)}
      other -> other
    end
  end

  @doc "Whether this pair has been called two different topics."
  def distinct?(%Tag{} = a, %Tag{} = b) do
    {tag_a_id, tag_b_id} = TagDistinction.ordered(a, b)
    not is_nil(get_distinction(tag_a_id, tag_b_id))
  end

  @doc """
  Files `name` as an alternative name for `canonical` without there ever having
  been a tag by that name — an admin adding `ROR` before anyone types it, so the
  duplicate is never minted in the first place.

  A name that **is** already a tag is refused with `{:error, :name_taken}`: that
  is a merge, and a merge has rows to move and a preview to show first.
  """
  def add_alias(%Tag{} = canonical, name, opts \\ []) do
    kind = Keyword.get(opts, :kind, "alias")
    name = Tag.normalize_value(to_string(name))

    cond do
      canonical.honor? ->
        {:error, :honor_tag}

      not is_nil(canonical.merged_into_id) ->
        {:error, :target_is_alias}

      not is_nil(Tag.find_by_value(name)) ->
        {:error, :name_taken}

      true ->
        %Tag{}
        |> Tag.changeset(%{"value" => name})
        |> Ecto.Changeset.put_change(:merged_into_id, canonical.id)
        |> Ecto.Changeset.put_change(:alias_kind, kind)
        |> Ecto.Changeset.validate_inclusion(:alias_kind, Tag.alias_kinds())
        |> Repo.insert()
    end
  end

  @doc """
  Drops an alternative name again.

  Only one that never carried anything: an alias left behind by a merge is
  undone by reverting that merge, not by deleting the row its slug lives on.
  """
  def remove_alias(%Tag{merged_into_id: nil}), do: {:error, :not_an_alias}

  def remove_alias(%Tag{} = tag_alias) do
    if merged?(tag_alias), do: {:error, :from_merge}, else: Repo.delete(tag_alias)
  end

  # An alias that came out of a merge is named by a ledger row; a hand-added one
  # is not, and only the latter is a plain mistake to take back.
  defp merged?(%Tag{id: id}) do
    Repo.exists?(from(m in TagMerge, where: m.absorbed_tag_id == ^id and is_nil(m.reverted_at)))
  end

  @doc """
  Whether two names differ **only** in characters the slugifier deletes.

  `c` and `c++` do, and they are two languages (#1337): a merge of such a pair
  is refused as a rule rather than left to judgement, because every
  normalization that could propose it has already thrown away the one thing
  telling them apart. A pair differing in a separator (`open source` /
  `OpenSource`) does not — the slugifier folds those, it does not drop them, and
  that pair is the ordinary mechanical variant a merge is *for*.
  """
  def punctuation_only_difference?(a, b) when is_binary(a) and is_binary(b) do
    keep(a) != keep(b) and strip(a) == strip(b)
  end

  @doc """
  The merges recorded so far, newest first, with both tags and the admin loaded.
  """
  def history(limit \\ 50) do
    Repo.all(
      from(m in TagMerge,
        order_by: [desc: m.id],
        limit: ^limit,
        preload: [:canonical_tag, :absorbed_tag, :admin_user]
      )
    )
  end

  @doc "One recorded merge, with everything the admin screen shows."
  def get_merge(id) do
    Vutuv.UUIDv7.with_cast(id, fn uuid ->
      Repo.one(
        from(m in TagMerge,
          where: m.id == ^uuid,
          preload: [:canonical_tag, :absorbed_tag, :admin_user]
        )
      )
    end)
  end

  # --- refusals -------------------------------------------------------------

  defp check(%Tag{id: same}, %Tag{id: same}), do: {:error, :same_tag}
  defp check(%Tag{honor?: true}, _), do: {:error, :honor_tag}
  defp check(_, %Tag{honor?: true}), do: {:error, :honor_tag}
  defp check(%Tag{merged_into_id: id}, _) when not is_nil(id), do: {:error, :already_merged}
  defp check(_, %Tag{merged_into_id: id}) when not is_nil(id), do: {:error, :target_is_alias}

  defp check(%Tag{} = absorbed, %Tag{} = canonical) do
    cond do
      distinct?(absorbed, canonical) ->
        {:error, :marked_distinct}

      punctuation_only_difference?(absorbed.name, canonical.name) ->
        {:error, :punctuation_only_difference}

      true ->
        :ok
    end
  end

  # What the slugifier keeps of a name: case folded and separators removed, so
  # only the characters that survive slugification are compared.
  defp keep(name) do
    name |> String.downcase() |> String.replace(~r/[\s_-]+/u, "")
  end

  # The same, minus everything `SlugHelpers.slugify_downcase/1`'s character
  # filter deletes — `+`, `#`, `/`, `.`, and every other non-word symbol. Two
  # names that agree here but not in `keep/1` are told apart by exactly those
  # deleted characters.
  defp strip(name), do: name |> keep() |> String.replace(~r/[^\w]/u, "")

  # --- moving rows ----------------------------------------------------------

  defp move_rows(repo, absorbed, canonical) do
    Enum.reduce(@movable, %{counts: %{}, moves: [], deletes: []}, fn {table, owner}, acc ->
      move_table(repo, table, owner, absorbed, canonical, acc)
    end)
  end

  defp move_table(repo, table, owner, absorbed, canonical, acc) do
    moved_ids =
      query_column(repo, movable_ids_sql(table, owner), params(owner, absorbed, canonical))

    # The rows are re-filed, not edited: `updated_at` stays as it was, so a
    # revert really does restore the state rather than something like it.
    if moved_ids != [] do
      repo.query!(
        "update #{table} set tag_id = $1::text::uuid where id = any($2::text[]::uuid[])",
        [canonical.id, moved_ids]
      )
    end

    acc =
      acc
      |> put_in([:counts, table], length(moved_ids))
      |> add_move(table, "tag_id", absorbed.id, moved_ids)

    drop_leftovers(repo, table, owner, absorbed, canonical, acc)
  end

  # Whatever is still filed under the absorbed tag now belongs to an owner who
  # already holds the canonical one, so it cannot come along. Captured whole
  # first, then deleted.
  defp drop_leftovers(_repo, _table, nil, _absorbed, _canonical, acc), do: acc

  defp drop_leftovers(repo, table, _owner, absorbed, canonical, acc) do
    acc =
      if table == "user_tags", do: rescue_endorsements(repo, absorbed, canonical, acc), else: acc

    rows =
      repo
      |> query_column("select to_jsonb(t) from #{table} t where t.tag_id = $1::text::uuid", [
        absorbed.id
      ])

    if rows == [] do
      acc
    else
      repo.query!("delete from #{table} where tag_id = $1::text::uuid", [absorbed.id])
      add_delete(acc, table, rows)
    end
  end

  # A member who carried both spellings loses one `user_tags` row, and deleting
  # it would cascade the endorsements under it. The vouches are what somebody
  # else said about this person, so they move onto the row that survives —
  # except where that endorser already vouched for the surviving row, which the
  # `(user_id, user_tag_id)` unique index forbids and which is the same vouch
  # anyway. Those few are captured for the revert and go with the row.
  defp rescue_endorsements(repo, absorbed, canonical, acc) do
    %{rows: rows} =
      repo.query!(
        """
        with doomed as (
          select a.id as doomed_id, b.id as survivor_id
          from user_tags a
          join user_tags b on b.user_id = a.user_id and b.tag_id = $2::text::uuid
          where a.tag_id = $1::text::uuid
        )
        select e.id::text, d.doomed_id::text, d.survivor_id::text
        from user_tag_endorsements e
        join doomed d on d.doomed_id = e.user_tag_id
        where not exists (
          select 1 from user_tag_endorsements x
          where x.user_tag_id = d.survivor_id and x.user_id = e.user_id
        )
        """,
        [absorbed.id, canonical.id]
      )

    # Captured before the move, because a doomed row's remaining endorsements
    # are about to be cascade-deleted with it.
    doomed_endorsements =
      query_column(
        repo,
        """
        select to_jsonb(e)
        from user_tag_endorsements e
        join user_tags a on a.id = e.user_tag_id
        join user_tags b on b.user_id = a.user_id and b.tag_id = $2::text::uuid
        where a.tag_id = $1::text::uuid
        """,
        [absorbed.id, canonical.id]
      )

    acc =
      rows
      |> Enum.group_by(fn [_id, doomed_id, _survivor] -> doomed_id end, fn [id, _, survivor] ->
        {id, survivor}
      end)
      |> Enum.reduce(acc, fn {doomed_id, pairs}, acc ->
        ids = Enum.map(pairs, &elem(&1, 0))
        [{_, survivor_id} | _] = pairs

        repo.query!(
          "update user_tag_endorsements set user_tag_id = $1::text::uuid " <>
            "where id = any($2::text[]::uuid[])",
          [survivor_id, ids]
        )

        add_move(acc, "user_tag_endorsements", "user_tag_id", doomed_id, ids)
      end)

    moved_ids = Enum.map(rows, fn [id, _, _] -> id end)

    case Enum.reject(doomed_endorsements, &(&1["id"] in moved_ids)) do
      [] -> acc
      leftovers -> add_delete(acc, "user_tag_endorsements", leftovers)
    end
  end

  # --- reverting ------------------------------------------------------------

  defp restore(repo, undo) do
    # Parents before children: a re-inserted endorsement points at a `user_tags`
    # row that has to exist again first.
    undo
    |> Map.get("deletes", [])
    |> Enum.sort_by(&(&1["table"] == "user_tag_endorsements"))
    |> Enum.each(fn %{"table" => table, "rows" => rows} ->
      Enum.each(rows, fn row ->
        repo.query!(
          "insert into #{safe_table(table)} select * from jsonb_populate_record(null::#{safe_table(table)}, $1::jsonb)",
          [row]
        )
      end)
    end)

    undo
    |> Map.get("moves", [])
    |> Enum.each(fn %{"table" => table, "column" => column, "to" => to, "ids" => ids} ->
      if ids != [] do
        repo.query!(
          "update #{safe_table(table)} set #{safe_column(table, column)} = $1::text::uuid " <>
            "where id = any($2::text[]::uuid[])",
          [to, ids]
        )
      end
    end)

    :ok
  end

  # The undo payload is ours, but it round-trips through the database as JSON,
  # so the table and column names it names are checked against the compile-time
  # list before they reach a query rather than trusted for having been written
  # by us once.
  @tables ["user_tag_endorsements" | Enum.map(@movable, &elem(&1, 0))]
  @columns %{"user_tag_endorsements" => "user_tag_id"}

  # Fail closed: an unknown name raises rather than being skipped, so a payload
  # that does not match this list stops the revert instead of half-applying it.
  defp safe_table(table) when table in @tables, do: table

  defp safe_column(table, column) do
    expected = Map.get(@columns, safe_table(table), "tag_id")
    if expected == column, do: column, else: raise(ArgumentError, "unknown column #{column}")
  end

  # --- plumbing -------------------------------------------------------------

  defp movable_ids_sql(table, nil) do
    "select id::text from #{table} where tag_id = $1::text::uuid"
  end

  defp movable_ids_sql(table, owner) do
    """
    select a.id::text from #{table} a
    where a.tag_id = $1::text::uuid
      and not exists (
        select 1 from #{table} b
        where b.tag_id = $2::text::uuid and b.#{owner} = a.#{owner}
      )
    """
  end

  # A table with no owner column cannot collide, so its query names one tag and
  # takes one parameter; passing a second would be a bind error, not a no-op.
  defp params(nil, absorbed, _canonical), do: [absorbed.id]
  defp params(_owner, absorbed, canonical), do: [absorbed.id, canonical.id]

  defp query_column(repo, sql, params) do
    %{rows: rows} = repo.query!(sql, params)
    Enum.map(rows, fn [value] -> value end)
  end

  defp put_count(acc, _key, _table, 0), do: acc
  defp put_count(acc, key, table, count), do: put_in(acc, [key, table], count)

  defp add_move(acc, _table, _column, _to, []), do: acc

  defp add_move(acc, table, column, to, ids) do
    move = %{"table" => table, "column" => column, "to" => to, "ids" => ids}
    Map.update!(acc, :moves, &(&1 ++ [move]))
  end

  defp add_delete(acc, table, rows) do
    Map.update!(acc, :deletes, &(&1 ++ [%{"table" => table, "rows" => rows}]))
  end

  defp get_distinction(tag_a_id, tag_b_id) do
    Repo.one(
      from(d in TagDistinction, where: d.tag_a_id == ^tag_a_id and d.tag_b_id == ^tag_b_id)
    )
  end

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
end
