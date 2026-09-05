defmodule Vutuv.QueryCounter do
  @moduledoc """
  Counts the Ecto queries a function runs:

      {result, count} = count_queries(fn -> ... end)

  `matching: regex_or_string` counts only the queries whose SQL matches — for
  asserting that one specific query shape (e.g. the action-bar engagement
  SELECT) runs exactly once per render instead of once per card.

  Telemetry handlers are global, so under async tests a parallel test's query
  would also fire ours. Ecto runs the handler synchronously in the process
  that called `Repo` (and ConnTest dispatches in the test process), so only
  events emitted from the calling process are counted.
  """

  def count_queries(fun, opts \\ []) do
    parent = self()
    count(fun, opts, &(&1 == parent), 0)
  end

  @doc """
  Like `count_queries/1` but counting queries from EVERY process, not only the
  caller — for asserting what a LiveView's *connected mount* ran: its queries
  execute in the view process and in Ecto's parallel-preload tasks, which the
  caller-filtered counter deliberately ignores. Run `get/2` first (the dead
  render), then count `live(conn)` (the connect) inside `fun`. The same goes
  for a load the profile mount runs in tasks of its own (its counts), which
  the caller-filtered counter never sees even on the dead render. `matching:`
  narrows to one query shape, as in `count_queries/2`.

  Only meaningful in a **sync** (`async: false`) test module: an async
  neighbour's queries would land in the window too.
  """
  def count_queries_global(fun, opts \\ []), do: count(fun, opts, fn _ -> true end, 100)

  # `from?` decides whose queries count (the caller's, or everyone's) and
  # `settle_ms` how long to wait for the last one: other processes' telemetry
  # sends may still be in flight when `fun` returns, so the global count waits
  # a beat before concluding the stream is dry, the same-process one need not.
  defp count(fun, opts, from?, settle_ms) do
    parent = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref}
    matching = Keyword.get(opts, :matching)

    :telemetry.attach(
      handler_id,
      [:vutuv, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if from?.(self()) and (matching == nil or metadata.query =~ matching),
          do: send(parent, {ref, :query})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain_queries(ref, 0, settle_ms)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(ref, acc, settle_ms) do
    receive do
      {^ref, :query} -> drain_queries(ref, acc + 1, settle_ms)
    after
      settle_ms -> acc
    end
  end
end
