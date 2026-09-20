defmodule Vutuv.SearchPeopleIndexTest do
  @moduledoc """
  The people search and its trigram index have to spell one expression the same
  way, and nothing reports it when they drift.

  `Vutuv.SearchText.name_ilike/3` matches `first_name || ' ' || last_name`, and
  `20260920140428_add_users_full_name_trigram_index` indexes that expression.
  A GIN expression index is used only when the query's expression normalizes to
  the index's, so rewriting either side — `concat/3` instead of `||`, a
  `coalesce` around a column, a second space — takes the index out of the plan
  **silently**: same rows, same order, a sequential scan per keystroke.

  So this walks the two real sources rather than a copy of either: the SQL Ecto
  emits for the query, and the definition Postgres stored for the index.
  """
  use Vutuv.DataCase, async: true

  import Ecto.Query
  import Vutuv.SearchText, only: [name_ilike: 3]

  alias Ecto.Adapters.SQL
  alias Vutuv.Accounts
  alias Vutuv.Accounts.User

  test "the query and the index name the same concatenation" do
    {sql, _params} =
      SQL.to_sql(
        :all,
        Repo,
        from(u in User, where: name_ilike(u.first_name, u.last_name, ^"%x%"), select: u.id)
      )

    assert sql =~ ~s{u0."first_name" || ' ' || u0."last_name"}

    %{rows: rows} =
      Repo.query!(
        "select indexdef from pg_indexes where tablename = 'users' and indexname = $1",
        ["users_full_name_trgm_index"]
      )

    assert [[indexdef]] = rows, "the migration did not create users_full_name_trgm_index"

    # Postgres stores the expression normalized (explicit ::text casts, its own
    # parentheses), so match its shape rather than the literal we wrote: the
    # same two-step concatenation, in the same order, with one space between.
    assert indexdef =~ ~r/first_name\)?::text \|\| ' '::text\)? \|\| \(?last_name/
    assert indexdef =~ "USING gin"
    assert indexdef =~ "gin_trgm_ops"
  end

  test "a name the concatenation alone can match is found" do
    # The arm this index exists for: neither column holds "Ada Sucherin", and
    # the index must not change which rows come back.
    me = insert(:activated_user, first_name: "Zoe", last_name: "Andere")
    target = insert(:activated_user, first_name: "Ada", last_name: "Sucherin")

    found = Accounts.search_people(me, "Ada Sucherin")

    assert Enum.map(found, & &1.id) == [target.id]
  end
end
