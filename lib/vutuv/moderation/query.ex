defmodule Vutuv.Moderation.Query do
  @moduledoc """
  The one SQL spelling of "this account is hidden by moderation" — the query
  twin of `Vutuv.Moderation.account_hidden?/1`. `Vutuv.Posts.scope_visible/2`
  and `Vutuv.Search` both build on it, so a future hidden state (or a changed
  suspension boundary) is one edit here plus the struct predicate.

  It also holds `case_event_at/1`, the one expression for when a moderation case
  last said something to its owner.
  """

  @doc """
  When this case last said something to its owner: the ruling if there is one,
  otherwise the moment the report arrived.

  The owner's notification list is **one row per case, rewritten in place**, so
  its time has to be the time of what the row currently says. It was the case's
  `inserted_at`, so a ruling days later kept the row where it had always been,
  with the hour of the complaint on it, and the member was never told their
  content had come back (issue #2067) — the answer `moderation_reports`'
  `outcome_notified_at` gives one kind over: stamp the event, not the trigger.

  It lives here rather than beside its readers because ordering, keyset cursor,
  `max` and unread count must all ask the identical expression or the cursor and
  the ordering stop agreeing. Use inside `order_by:` / `where:` / `select:` on a
  `moderation_cases` binding after `import Vutuv.Moderation.Query`.

  Deliberately **not** `coalesce(resolved_at, escalated_at, inserted_at)`: a
  member disputing their own case escalates it, and a row rising to the top of
  their notifications because of their own click is noise, not news.
  """
  defmacro case_event_at(c) do
    quote do: coalesce(unquote(c).resolved_at, unquote(c).inserted_at)
  end

  @doc """
  True when the account behind `user_id` (a column reference) is hidden:
  frozen pending review, deactivated, currently suspended, or unreachable
  (every email bounced; see `Vutuv.Deliverability`). Correlated `EXISTS`
  against the users PK, so it composes into any query without a join. Use
  inside `where:`/`dynamic` after `import Vutuv.Moderation.Query`. Kept in step
  with the struct predicate `Vutuv.Moderation.account_hidden?/1`.
  """
  defmacro account_hidden(user_id) do
    quote do
      fragment(
        """
        EXISTS (SELECT 1 FROM users mu
                WHERE mu.id = ?
                  AND (mu.frozen_at IS NOT NULL
                    OR mu.deactivated_at IS NOT NULL
                    OR mu.unreachable_at IS NOT NULL
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

  The `unreachable_at` arm mirrors `account_hidden/1` (and the struct predicate
  `Vutuv.Moderation.account_hidden?/1`): an account whose every email bounced is
  a zombie nobody can reach and stays out of the public network.
  """
  defmacro account_hidden_row(u) do
    quote do
      fragment(
        "(? IS NOT NULL OR ? IS NOT NULL OR ? IS NOT NULL OR (? IS NOT NULL AND ? > (NOW() AT TIME ZONE 'utc')))",
        unquote(u).frozen_at,
        unquote(u).deactivated_at,
        unquote(u).unreachable_at,
        unquote(u).suspended_until,
        unquote(u).suspended_until
      )
    end
  end

  @doc """
  True when the account row `u` is **confirmed**: its `email_confirmed?` flag is
  set, or `NULL` for the legacy members who predate the flag (they count as
  confirmed). The visibility companion to `account_hidden_row/1` — a member is
  listed publicly when `account_confirmed_row(u) and not account_hidden_row(u)`.
  Use it on an already-in-scope users row `u` (a join or the main binding); the
  one spelling of the confirmed-or-legacy-NULL gate that was hand-written at
  every people-listing query.
  """
  defmacro account_confirmed_row(u) do
    quote do
      is_nil(unquote(u).email_confirmed?) or unquote(u).email_confirmed? == true
    end
  end
end
