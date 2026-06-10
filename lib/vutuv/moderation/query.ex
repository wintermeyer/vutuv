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
end
