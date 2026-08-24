defmodule Vutuv.WorkCounter do
  @moduledoc """
  Counts the *work* a function does, in BEAM reductions:

      {work, html} = count_reductions(fn -> Markdown.render(body) end)
      assert work < 5_000_000

  The shape mirrors `:timer.tc/1` on purpose, because it replaces it at the
  handful of call sites that guard an algorithm against going quadratic — a
  ReDoS bump-along, an autolink scan over a pathological token, a zip whose
  entries all point at one stream.

  Those guards asked the wall clock, and the wall clock answers a different
  question. `mix test` runs twenty cases in parallel, so the render in
  `markdown_test.exs` — 3 ms of actual work — was once measured at 1.16 s
  purely because the scheduler had other tenants, and its `< 1s` bound failed
  a push on a busy laptop while passing on an idle CI box. Raising such a bound
  buys time, it does not fix the instrument: what these tests want to know is
  how much work the input causes, and that is what a reduction counts.

  So the count is stable across a loaded machine and an idle one, and it still
  sees the thing being guarded. Reductions track NIF work too: a catastrophic
  `:re` backtrack charges about 1.25 million of them, so a regex guard is
  measurable this way as well.

  Two limits worth knowing. Reductions are charged per **process**, so work a
  function hands off to a `Task` is invisible here (every current caller is
  in-process — check before adding one that is not). And the count drifts a
  little with the Elixir/OTP version and with library upgrades, so a threshold
  wants an order of magnitude of headroom rather than a tight fit. The guards
  have it: each one separates a linear cost from a quadratic one, and every
  bound in the tree was calibrated by measuring both sides.
  """

  @doc """
  Runs `fun` and returns `{reductions, result}`.
  """
  def count_reductions(fun) do
    {:reductions, before} = Process.info(self(), :reductions)
    result = fun.()
    {:reductions, afterwards} = Process.info(self(), :reductions)
    {afterwards - before, result}
  end
end
