defmodule Vutuv.Repo.Migrations.BackfillHashtagFilings do
  use Ecto.Migration

  # Files every post already stored under the tags its `#hashtags` name, so the
  # tag pages read the same the day this ships as they will for everything
  # written after it. Without it the feature would only apply to new posts, and
  # `/tags/berlin` would keep missing years of posts that say `#berlin` — which
  # is the whole complaint the two new tables answer (`post_hashtags`,
  # `fediverse_post_tags`).
  #
  # Existing tags only, matched case-insensitively on name or slug, exactly like
  # `Vutuv.Tags.tag_ids_for_hashtags/1`: the backfill mints no tag either.
  #
  # Data-only and idempotent (`ON CONFLICT DO NOTHING`), so a re-run is a no-op
  # and it is safe to leave in place. N-1 safe: the currently deployed release
  # does not know these tables exist.

  # A snapshot of the hashtag arm of `Vutuv.Mentions`' entity grammar, and of
  # the code-span split beside it, deliberately copied rather than called: a
  # migration must keep meaning what it meant the day it ran, however that
  # module later evolves. `#` may not sit mid-token (no `/path#frag`, no `&#39;`),
  # and a `#foo` inside code is sample text, never a tag.
  @hashtag ~r/(?<![\w#\/&])#([A-Za-z0-9_]+)/
  @code ~r/```[\s\S]*?```|~~~[\s\S]*?~~~|`[^`\n]*`/

  # One INSERT per this many filings.
  @chunk 500

  def up do
    tags = tag_ids_by_name()

    if map_size(tags) > 0 do
      backfill("posts", "body", "post_hashtags", "post_id", tags)
      backfill("fediverse_posts", "content_text", "fediverse_post_tags", "remote_post_id", tags)
    end
  end

  # Not reversible: the filings are re-derived on every save from here on, so
  # dropping them would only make the tag pages wrong until each post is edited.
  def down, do: :ok

  # Every spelling that resolves a hashtag to a tag: the lowercased name and the
  # slug both point at the tag's id.
  defp tag_ids_by_name do
    %{rows: rows} = repo().query!("SELECT id::text, lower(name), slug FROM tags", [])

    for [id, name, slug] <- rows, key <- Enum.uniq([name, slug]), is_binary(key), into: %{} do
      {key, id}
    end
  end

  defp backfill(source_table, body_column, join_table, post_column, tags) do
    %{rows: rows} =
      repo().query!(
        "SELECT id::text, #{body_column} FROM #{source_table} WHERE #{body_column} LIKE '%#%'",
        []
      )

    rows
    |> Enum.flat_map(fn [id, body] -> filings(id, body, tags) end)
    |> Enum.chunk_every(@chunk)
    |> Enum.each(&insert_filings(join_table, post_column, &1))
  end

  defp filings(id, body, tags) when is_binary(body) do
    body
    |> hashtags()
    |> Enum.map(&Map.get(tags, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(&{id, &1})
  end

  defp filings(_id, _body, _tags), do: []

  defp hashtags(body) do
    @code
    |> Regex.split(body, include_captures: true)
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {chunk, index} when rem(index, 2) == 0 ->
        @hashtag |> Regex.scan(chunk, capture: :all_but_first) |> List.flatten()

      {_code, _index} ->
        []
    end)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp insert_filings(join_table, post_column, filings) do
    now = NaiveDateTime.utc_now(:second)

    {placeholders, params} =
      filings
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {{post_id, tag_id}, index}, {rows, params} ->
        base = index * 5

        # `::text::uuid` and not a bare `::uuid`: Postgres reports the parameter
        # type of `$1::uuid` as `uuid`, and Postgrex then demands the raw
        # 16-byte form, so the readable `019f…` strings this works in would
        # raise an EncodeError. Casting from text hands Postgres the string and
        # lets it parse the uuid, which is what every id here already is.
        {
          [
            "($#{base + 1}::text::uuid, $#{base + 2}::text::uuid, $#{base + 3}::text::uuid, $#{base + 4}::timestamp, $#{base + 5}::timestamp)"
            | rows
          ],
          params ++ [Vutuv.UUIDv7.generate(), post_id, tag_id, now, now]
        }
      end)

    repo().query!(
      """
      INSERT INTO #{join_table} (id, #{post_column}, tag_id, inserted_at, updated_at)
      VALUES #{Enum.join(Enum.reverse(placeholders), ", ")}
      ON CONFLICT DO NOTHING
      """,
      params
    )
  end
end
