defmodule Vutuv.Repo.Migrations.RetagSlugsToActorGrammar do
  @moduledoc """
  Brings every live tag slug into the actor grammar `^[a-z0-9_]+$` (issues
  #1337 and #1332, want 2), keeping the spelling it had reachable.

  Three shapes sat in the column: underscores (the older majority, already
  conforming), hyphens (what the slugifier wrote until now) and a `.<short-sha>`
  collision suffix. 262 live tags needed a new slug on the catalog this was
  measured against.

  **Three resolutions, in this order.** They exist because the wanted slug is
  often held by another row, and by what kind of row decides what is right:

  1. `:free` — nobody holds it. Rename, and file the old spelling as a `former`
     alias row so `/tags/<old>` answers 301 instead of 404.
  2. `:swap` — it is held by an **alias of this very tag**, which is what
     #1338's merge pass left behind: `open_source_software` was merged into
     `open-source-software`, so the underscore spelling the grammar now wants is
     already sitting on the absorbed row. Both slugs already resolve to one
     topic, so the two rows exchange them. No row is added and nothing changes
     meaning.
  3. `:suffix` — held by an unrelated topic. Only then a `_<sha>` suffix, and
     never silently: the count is printed.

  Order matters even among the free ones. `c++` held the readable `c`, so the
  real C sat behind `c.64f34779`; renaming `c++` to `cpp` is what frees `c` — but
  only for the alias row that then records it, so C keeps a suffix rather than
  quietly taking over a URL that has meant C++ all along.

  Reversible: `down/0` reads the alias rows this created (and the swaps) and puts
  the old slugs back.
  """
  use Ecto.Migration

  import Ecto.Query

  alias Vutuv.Repo
  alias Vutuv.SlugHelpers

  @grammar ~r/^[a-z0-9_]+$/
  @alias_kind "former"

  def up do
    plan = plan()
    Enum.each(plan, &apply_step/1)
    IO.puts(report(plan))
  end

  def down do
    # Two shapes to undo, and in this order. The rows `up/0` **created** carry a
    # signature it alone writes (a `former` alias whose name is its own slug,
    # and that slug is not an actor name): delete each and give the old slug
    # back. What is left in that shape afterwards is a **swap** — a pre-existing
    # alias, so it has a name of its own — and those two rows exchange their
    # slugs back.
    for %{id: alias_id, slug: old_slug, merged_into_id: canonical_id} <- created_aliases() do
      delete_row(alias_id)
      set_slug(canonical_id, old_slug)
    end

    for %{alias_id: alias_id, alias_slug: alias_slug, id: id, slug: slug} <- swapped_pairs() do
      parking = "swap_#{short_sha()}"
      set_slug(alias_id, parking)
      set_slug(id, alias_slug)
      set_slug(alias_id, slug)
    end

    :ok
  end

  @doc """
  What `up/0` would do, without doing it. Run it before the migration on a copy
  of the real catalog:

      mix run -e 'IO.puts(Vutuv.Repo.Migrations.RetagSlugsToActorGrammar.dry_run())'
  """
  def dry_run, do: report(plan())

  defp report(plan) do
    counts = Enum.frequencies_by(plan, & &1.resolution)
    suffixed = Enum.filter(plan, &(&1.resolution == :suffix))

    [
      "retag plan: #{length(plan)} live slugs",
      "  free   (rename + former alias): #{Map.get(counts, :free, 0)}",
      "  swap   (with own alias row):    #{Map.get(counts, :swap, 0)}",
      "  suffix (wanted slug taken):     #{Map.get(counts, :suffix, 0)}"
      | Enum.map(suffixed, fn s -> "    #{s.slug} -> #{s.wanted}" end)
    ]
    |> Enum.join("\n")
  end

  # Every live tag whose slug is not an actor name yet, with the slug it wants
  # and how that slug can be had.
  defp plan do
    rows = all_rows()
    by_slug = Map.new(rows, &{&1.slug, &1})

    {conforming, to_rename} =
      rows
      |> Enum.filter(&is_nil(&1.merged_into_id))
      |> Enum.split_with(fn %{slug: slug} -> Regex.match?(@grammar, slug) end)

    _ = conforming
    taken = MapSet.new(rows, & &1.slug)

    to_rename
    |> Enum.map(&Map.put(&1, :wanted, wanted_slug(&1)))
    |> resolve(taken, by_slug, [])
  end

  # Apply what is free, then look again: a row can be blocked by another row
  # that is itself about to move. Whatever is still blocked when a pass makes no
  # progress is either this tag's own absorbed spelling (swap) or a different
  # topic (suffix).
  defp resolve([], _taken, _by_slug, done), do: Enum.reverse(done)

  defp resolve(pending, taken, by_slug, done) do
    {free, blocked} = Enum.split_with(pending, &(not MapSet.member?(taken, &1.wanted)))

    if free == [] do
      Enum.reverse(done) ++ Enum.map(blocked, &block_resolution(&1, by_slug))
    else
      taken = Enum.reduce(free, taken, &MapSet.put(&2, &1.wanted))
      free = Enum.map(free, &Map.put(&1, :resolution, :free))
      resolve(blocked, taken, by_slug, Enum.reverse(free) ++ done)
    end
  end

  defp block_resolution(row, by_slug) do
    case Map.get(by_slug, row.wanted) do
      %{id: holder_id, merged_into_id: canonical_id} when canonical_id == row.id ->
        row |> Map.put(:resolution, :swap) |> Map.put(:swap_with, holder_id)

      _ ->
        row |> Map.put(:resolution, :suffix) |> Map.put(:wanted, kept_suffix(row, by_slug))
    end
  end

  # A blocked row is a second topic under a name somebody else already holds
  # (`#Grafana` beside `Grafana`), which is a merge for a human to decide and
  # never for a migration. It keeps a page of its own, so all it needs is a
  # conforming slug — and the one it already has is the best candidate: a
  # `.<sha>` collision suffix becomes `_<sha>`, one character changed, so the
  # URL stays recognisable and the alias 301 covers the old spelling. Only when
  # even that is taken is a fresh suffix minted.
  @dotted ~r/^(?<base>.+)\.(?<sha>[a-f0-9]{4,16})$/

  defp kept_suffix(%{slug: slug, wanted: wanted}, by_slug) do
    candidate =
      case Regex.named_captures(@dotted, slug) do
        %{"base" => base, "sha" => sha} -> "#{SlugHelpers.tagify(base)}_#{sha}"
        nil -> "#{wanted}_#{short_sha()}"
      end

    if Map.has_key?(by_slug, candidate), do: "#{wanted}_#{short_sha()}", else: candidate
  end

  defp wanted_slug(%{name: name, slug: slug}) do
    case SlugHelpers.tagify(name) do
      "" -> fallback_slug(slug)
      wanted -> wanted
    end
  end

  # A name that slugifies to nothing (pure non-ASCII) keeps whatever of its old
  # slug is usable, and a generated one when even that is empty.
  defp fallback_slug(slug) do
    case SlugHelpers.tagify(slug) do
      "" -> short_sha()
      usable -> usable
    end
  end

  defp apply_step(%{resolution: :swap, id: id, slug: old_slug, wanted: wanted, swap_with: other}) do
    # Both slugs already resolve to this one topic, so the pair simply exchanges
    # them. Through a parking slug, because the unique index sees each statement.
    parking = "swap_#{short_sha()}"
    set_slug(other, parking)
    set_slug(id, wanted)
    set_slug(other, old_slug)
  end

  defp apply_step(%{id: id, slug: old_slug, wanted: wanted}) do
    set_slug(id, wanted)
    insert_former_alias(id, old_slug)
  end

  defp set_slug(id, slug) do
    Repo.query!("update tags set slug = $1, updated_at = $2 where id = $3", [slug, now(), uuid(id)])
  end

  defp delete_row(id), do: Repo.query!("delete from tags where id = $1", [uuid(id)])

  # The old spelling as a `former` alias row: that is what makes `/tags/<old>`
  # answer 301 (`TagController.resolve_tag/2`) and what keeps a literal
  # `#hashtag` in an old post body resolving (`Tags.linkable_slugs/1`). Its name
  # is the retired slug, because that is what the row records — the topic's own
  # name stays on the row that survived.
  defp insert_former_alias(canonical_id, old_slug) do
    Repo.query!(
      """
      insert into tags (id, slug, name, merged_into_id, alias_kind, inserted_at, updated_at)
      values ($1, $2, $3, $4, $5, $6, $6)
      """,
      [uuid(Vutuv.UUIDv7.generate()), old_slug, old_slug, uuid(canonical_id), @alias_kind, now()]
    )
  end

  defp all_rows do
    from(t in "tags",
      select: %{id: t.id, name: t.name, slug: t.slug, merged_into_id: t.merged_into_id}
    )
    |> Repo.all()
  end

  # The rows `up/0` added, by the signature it alone writes: a `former` alias
  # whose **name is its own slug** (a retired spelling records nothing else) and
  # whose slug is not an actor name.
  defp created_aliases do
    from(t in "tags",
      where: t.alias_kind == @alias_kind and not is_nil(t.merged_into_id) and t.name == t.slug,
      select: %{id: t.id, slug: t.slug, merged_into_id: t.merged_into_id}
    )
    |> Repo.all()
    |> Enum.reject(fn %{slug: slug} -> Regex.match?(@grammar, slug) end)
  end

  # A canonical row wearing the slug its own name produces, while its alias
  # holds a spelling that is not an actor name — which is what a swap leaves
  # behind, and (once the rows created above are gone) nothing else does. The
  # test is against the **name**, not against the alias's slug: the canonical
  # took `tagify(name)`, which for `C/C++` is `c_cpp` and has nothing to do with
  # the `c_c.847f12e2` the alias ended up holding.
  defp swapped_pairs do
    from(t in "tags",
      join: a in "tags",
      on: a.merged_into_id == t.id,
      where: is_nil(t.merged_into_id),
      select: %{id: t.id, name: t.name, slug: t.slug, alias_id: a.id, alias_slug: a.slug}
    )
    |> Repo.all()
    |> Enum.filter(fn %{name: name, slug: slug, alias_slug: alias_slug} ->
      Regex.match?(@grammar, slug) and not Regex.match?(@grammar, alias_slug) and
        SlugHelpers.tagify(name) == slug
    end)
  end

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  # A readable id string cannot go into a `uuid` parameter: Postgres reports the
  # type as `uuid` and Postgrex then wants the raw 16 bytes, which is the
  # `DBConnection.EncodeError` the ecto rules warn about.
  defp uuid(id) when is_binary(id) do
    case Ecto.UUID.dump(id) do
      {:ok, raw} -> raw
      :error -> id
    end
  end

  defp short_sha, do: 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
