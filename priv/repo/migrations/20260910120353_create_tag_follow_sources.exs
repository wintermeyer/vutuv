defmodule Vutuv.Repo.Migrations.CreateTagFollowSources do
  use Ecto.Migration

  # Where a followed tag's posts should come from (issue #2125). A follow was a
  # member (or a page) and a topic, with nowhere to say *where*; it now carries
  # sources, one row each: `vutuv` for this installation plus any server the
  # member picked.
  #
  # A table rather than a list on the follow, because the fetcher's question is
  # the other way round — which server-and-tag pairs does anybody here want? —
  # and that is one grouped query instead of unpacking every member's array.
  #
  # The backfill writes exactly one source, `vutuv`, to every follow that
  # already exists, members and pages alike, so nothing changes for anybody
  # until they add a server themselves. Plain addition, and the currently
  # deployed release does not know the table exists, so this is N-1 safe and
  # needs no second deploy.

  # `vutuv` spelled out rather than read from the app: a migration must keep
  # meaning what it meant the day it ran, whatever the constant later becomes.
  @local_source "vutuv"

  # Ids per statement. The ids are minted here because they must be UUID v7 and
  # Postgres has no generator for that.
  @chunk 1000

  def up do
    create table(:tag_follow_sources) do
      add(
        :tag_follow_id,
        references(:tag_follows, on_delete: :delete_all, type: :binary_id),
        null: false
      )

      # Either the literal `vutuv` or a bare lowercased hostname — never a URL.
      add(:source, :string, null: false)

      timestamps()
    end

    # One row per source of a follow; adding a server twice is a no-op, not a
    # duplicate. The leading tag_follow_id also serves "the sources of this
    # follow", so no separate index is needed for the card.
    create(unique_index(:tag_follow_sources, [:tag_follow_id, :source]))

    # The fetcher's side of the question, and partial on purpose: it asks only
    # about servers, and a plain index on `source` would be almost entirely the
    # local sentinel — which no query ever looks up, since the only predicate
    # against it is `<>` and a btree cannot answer that. Measured on 200,000
    # follows: 112 kB against 1,384 kB, and `wanted_tag_sources/0` reads 32
    # buffers on this side instead of seq-scanning 1,685.
    create(
      index(:tag_follow_sources, [:source, :tag_follow_id], where: "source <> '#{@local_source}'")
    )

    flush()

    IO.puts("create_tag_follow_sources: #{backfill(repo())} follow(s) given the local source")
  end

  def down do
    drop(table(:tag_follow_sources))
  end

  @doc """
  Gives every follow that has no source at all the local one, and answers how
  many rows that was. Idempotent, so a re-run adds nothing and a follow written
  by the new release (which sets its own source) is left alone.

  Takes the repo rather than reading `repo()`, so the test can drive the
  migration's own code instead of a copy of it.
  """
  def backfill(repo) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT tf.id::text
        FROM tag_follows tf
        WHERE NOT EXISTS (
          SELECT 1 FROM tag_follow_sources s WHERE s.tag_follow_id = tf.id
        )
        """,
        []
      )

    rows
    |> List.flatten()
    |> Enum.chunk_every(@chunk)
    |> Enum.reduce(0, fn follow_ids, written -> written + insert_local(repo, follow_ids) end)
  end

  defp insert_local(repo, follow_ids) do
    ids = Enum.map(follow_ids, fn _ -> Vutuv.UUIDv7.generate() end)
    now = NaiveDateTime.utc_now(:second)

    # `::text::uuid` and not a bare `::uuid`: Postgres reports the parameter
    # type of `$1::uuid[]` as uuid[], and Postgrex then demands the raw 16-byte
    # form, so the readable `019f…` strings minted above would raise an
    # EncodeError. Casting from text hands Postgres the string it can parse.
    %{num_rows: num_rows} =
      repo.query!(
        """
        INSERT INTO tag_follow_sources (id, tag_follow_id, source, inserted_at, updated_at)
        SELECT new_id::uuid, follow_id::uuid, $3, $4::timestamp, $4::timestamp
        FROM unnest($1::text[], $2::text[]) AS minted(new_id, follow_id)
        ON CONFLICT DO NOTHING
        """,
        [ids, follow_ids, @local_source, now]
      )

    num_rows
  end
end
