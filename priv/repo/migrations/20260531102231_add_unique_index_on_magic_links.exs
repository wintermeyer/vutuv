defmodule Vutuv.Repo.Migrations.AddUniqueIndexOnMagicLinks do
  use Ecto.Migration

  # `gen_magic_link/3` upserts the single magic link for a (user_id,
  # magic_link_type) pair by reading it with `Repo.one/1` first. Without a
  # unique index, two near-simultaneous requests for the same user and type
  # both read nil and both insert, leaving duplicate rows; the next `Repo.one`
  # then raises `Ecto.MultipleResultsError` (a 500). A unique index closes the
  # race at the database and lets the changeset surface it as a normal error.
  def up do
    # Drop any pre-existing duplicates first, keeping the newest row (highest
    # id) per pair, so the unique index can be created on legacy data. The
    # delete-with-self-join is spelled differently per database.
    dedup =
      case repo().__adapter__() do
        Ecto.Adapters.Postgres ->
          """
          DELETE FROM magic_links AS older
          USING magic_links AS newer
          WHERE older.user_id = newer.user_id
            AND older.magic_link_type = newer.magic_link_type
            AND older.id < newer.id
          """

        _ ->
          """
          DELETE older
          FROM magic_links AS older
          INNER JOIN magic_links AS newer
            ON older.user_id = newer.user_id
           AND older.magic_link_type = newer.magic_link_type
           AND older.id < newer.id
          """
      end

    execute(dedup)

    create(unique_index(:magic_links, [:user_id, :magic_link_type]))
  end

  def down do
    drop(unique_index(:magic_links, [:user_id, :magic_link_type]))
  end
end
