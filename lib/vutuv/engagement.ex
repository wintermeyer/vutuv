defmodule Vutuv.Engagement do
  @moduledoc """
  The idempotent "toggle a join row" insert shared by the engagement actions:
  post likes / bookmarks / reposts (`Vutuv.Posts`) and member likes / bookmarks
  (`Vutuv.Social`). Ids are minted in code, so the inserted row count, not a
  returned id, is what tells a fresh insert from the idempotent repeat.

  Only the insert kernel lives here. Each context keeps its own guards
  (post visibility vs. self / blocked), broadcast (post topic vs. actor topic)
  and return shape around it.
  """
  alias Vutuv.Repo
  alias Vutuv.UUIDv7

  @doc """
  Inserts a join row (stamped with a v7 id and `inserted_at`/`updated_at`)
  unless the unique `conflict_target` already holds it. `fields` are the row's
  own columns (e.g. `%{user_id: ..., post_id: ...}`). Returns `{:inserted, row}`
  on a fresh insert, or `:exists` when it was already there.
  """
  def insert_if_new(schema, fields, conflict_target) do
    now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
    row = Map.merge(fields, %{id: UUIDv7.generate(), inserted_at: now, updated_at: now})

    case Repo.insert_all(schema, [row],
           on_conflict: :nothing,
           conflict_target: conflict_target,
           returning: true
         ) do
      {0, _} -> :exists
      {1, [inserted]} -> {:inserted, inserted}
    end
  end
end
