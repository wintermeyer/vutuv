defmodule Vutuv.Moderation.Query do
  @moduledoc """
  The one SQL spelling of "this account is hidden by moderation" — the query
  twin of `Vutuv.Moderation.account_hidden?/1`. `Vutuv.Posts.scope_visible/2`
  and `Vutuv.Search` both build on it, so a future hidden state (or a changed
  suspension boundary) is one edit here plus the struct predicate.
  """

  @doc """
  True when the account behind `user_id` (a column reference) is hidden:
  frozen pending review, deactivated, or currently suspended. Correlated
  `EXISTS` against the users PK, so it composes into any query without a
  join. Use inside `where:`/`dynamic` after `import Vutuv.Moderation.Query`.
  """
  defmacro account_hidden(user_id) do
    quote do
      fragment(
        """
        EXISTS (SELECT 1 FROM users mu
                WHERE mu.id = ?
                  AND (mu.frozen_at IS NOT NULL
                    OR mu.deactivated_at IS NOT NULL
                    OR mu.suspended_until > (NOW() AT TIME ZONE 'utc')))
        """,
        unquote(user_id)
      )
    end
  end

  @doc """
  The row-bound twin of `account_hidden/1`: same definition of "hidden", but
  checked directly on an already-joined users row `u` instead of a correlated
  `EXISTS` that re-fetches the same row by id. Use it when the users row is
  already in scope (a join or the main binding) — it lets the planner read the
  columns it already has rather than running a subquery per candidate row
  (measured ~2x on the most-followed listing).

  The suspension arm is spelled `suspended_until IS NOT NULL AND ... > now`
  rather than the bare `> now` the EXISTS can afford: under `NOT(...)` a bare
  `NULL > now` would make a member with no moderation flags evaluate to NULL
  (and so vanish), which the EXISTS form sidesteps via its WHERE semantics.
  """
  defmacro account_hidden_row(u) do
    quote do
      fragment(
        "(? IS NOT NULL OR ? IS NOT NULL OR (? IS NOT NULL AND ? > (NOW() AT TIME ZONE 'utc')))",
        unquote(u).frozen_at,
        unquote(u).deactivated_at,
        unquote(u).suspended_until,
        unquote(u).suspended_until
      )
    end
  end
end
