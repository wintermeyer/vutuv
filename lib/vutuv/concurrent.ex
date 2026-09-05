defmodule Vutuv.Concurrent do
  @moduledoc """
  Independent database reads, run side by side.

  Reads of different tables that a page needs at once only add their latencies
  up when they run in a row: the newsfeed's ten sources cost 0.8 to 5.6 ms
  each and **31 ms in a row**, measured on a copy of production (2026-09-03),
  which was three quarters of the whole `/feed` dead render; the profile's
  loads told the same story (`VutuvWeb.UserProfileLive.load_profile/1`).
  `run/1` takes the thunks and returns their results in order.

  **At most four at once**, because the number bounds how much of the
  **connection pool** one request may hold, and production runs a pool of ten
  (`POOL_SIZE`, `config/runtime.exs`). Concurrency does not increase the total
  connection-time a request costs — the same queries occupy the same
  connection-milliseconds either way — it only shortens the span they are held
  over, so throughput is unchanged and latency is what improves. Ten in flight
  would still be safe by that argument and is not worth the shape of the
  failure it invites: one request able to empty the pool turns a slow query
  into a site-wide stall. Four takes most of the available saving and never
  holds more than 40 % of the pool. (Ecto's own parallel preload of a
  `Repo.preload/2` with several associations is not counted here; it fans out
  on its own terms.)

  `timeout: :infinity` hands the deadline to Ecto, which has its own per-query
  timeout; a second one here would only cut a query short in a way the caller
  cannot tell from a crash. A raising load still brings the request down,
  exactly as it did when these ran in a row. `$callers` travels into each
  task, which is what lets the Ecto SQL sandbox find the test's connection —
  so these stay plain `Task`s rather than anything supervised.
  """

  @max_concurrency 4

  @doc "Runs the zero-arity `loads` side by side and returns their results in order."
  def run(loads) when is_list(loads) do
    loads
    |> Task.async_stream(& &1.(), max_concurrency: @max_concurrency, timeout: :infinity)
    |> Enum.map(fn {:ok, result} -> result end)
  end
end
