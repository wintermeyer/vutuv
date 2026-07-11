defmodule Vutuv.Repo.Migrations.CreateHandlesRegistry do
  use Ecto.Migration

  import Ecto.Query, only: [from: 2]

  # Shared handle registry (issue #941): one namespace for member and company
  # @handles at the URL root (`/:handle`). Postgres cannot express a unique
  # constraint across two tables, so every handle owner points into this one
  # table whose UNIQUE(value) index is the single global uniqueness guarantee.
  # Copies the `viewer_exclusions` XOR-FK + CHECK pattern.
  #
  # Purely additive and N-1 backward compatible: the currently-deployed release
  # never touches `handles` and keeps resolving `/:slug` via `users.username`
  # (which the new resolver also does), so both slots stay correct across the
  # switch. Companies get a nullable, opt-in `username` handle; a company
  # without one is unchanged (reachable only at `/companies/:slug`).
  def up do
    create table(:handles) do
      # The handle, stored lowercased, e.g. "lufthansa". Same grammar/length as
      # a member username (validated in the schema); varchar(255) is far more
      # than the 15-char cap needs.
      add(:value, :string, null: false)
      # Exactly one owner (the CHECK below). ON DELETE cascades the row away
      # with its owner, so a deleted member/company frees its handle.
      add(:user_id, references(:users, on_delete: :delete_all))
      add(:company_id, references(:companies, on_delete: :delete_all))

      timestamps()
    end

    # The whole point: one handle value across the entire namespace.
    create(unique_index(:handles, [:value]))

    # One handle per owner (a member has exactly one, a company at most one).
    # Partial so the null owner of the other kind never collides.
    create(
      unique_index(:handles, [:user_id],
        where: "user_id IS NOT NULL",
        name: :handles_user_id_index
      )
    )

    create(
      unique_index(:handles, [:company_id],
        where: "company_id IS NOT NULL",
        name: :handles_company_id_index
      )
    )

    # Exactly one owner per row: a member XOR a company, never both, never
    # neither. The schema enforces the same rule; this is the last-resort DB
    # guard so a bad insert can't slip a meaningless row in.
    create(
      constraint(:handles, :handles_one_owner,
        check: "(user_id IS NOT NULL) <> (company_id IS NOT NULL)"
      )
    )

    alter table(:companies) do
      # Opt-in root handle. nil = "no root URL, still reachable at
      # /companies/:slug". Uniqueness lives in `handles`, so no per-table unique
      # index here — the registry is the single source of truth.
      add(:username, :string)
    end

    flush()

    backfill_user_handles()
  end

  def down do
    alter table(:companies) do
      remove(:username)
    end

    drop(table(:handles))
  end

  # Seed one registry row per existing member handle so the namespace is
  # complete on day one: the resolver, the auto-generated-handle collision
  # check and cross-table uniqueness all read `handles`, so every live
  # `users.username` must already be represented. Batched insert_all with
  # freshly minted UUID v7 ids (never v4 — house rule) and stamped timestamps.
  defp backfill_user_handles do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    from(u in "users",
      where: not is_nil(u.username),
      select: %{id: u.id, username: u.username}
    )
    |> repo().all()
    |> Enum.chunk_every(1000)
    |> Enum.each(fn chunk ->
      rows =
        Enum.map(chunk, fn %{id: user_id, username: username} ->
          %{
            # Schemaless insert_all: ids are raw 16-byte binaries, so dump the
            # freshly minted UUID v7 string to its binary form (never v4).
            id: Ecto.UUID.dump!(Vutuv.UUIDv7.generate()),
            value: username,
            user_id: user_id,
            inserted_at: now,
            updated_at: now
          }
        end)

      repo().insert_all("handles", rows)
    end)
  end
end
