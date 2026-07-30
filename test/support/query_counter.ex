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
    ref = make_ref()
    handler_id = {__MODULE__, ref}
    matching = Keyword.get(opts, :matching)

    :telemetry.attach(
      handler_id,
      [:vutuv, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == parent and (matching == nil or metadata.query =~ matching) do
          send(parent, {ref, :query})
        end
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain_queries(ref, 0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(ref, acc) do
    receive do
      {^ref, :query} -> drain_queries(ref, acc + 1)
    after
      0 -> acc
    end
  end
end
