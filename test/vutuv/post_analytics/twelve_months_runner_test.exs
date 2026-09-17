defmodule Vutuv.PostAnalytics.TwelveMonthsRunnerTest do
  @moduledoc """
  The background owner of the investor page's 12-month reach
  (`Vutuv.PostAnalytics.TwelveMonthsRunner`): one run at a time however many people
  watch, its steps broadcast as they finish, the result kept for a while, and a
  failed run reported rather than left spinning.

  Each test starts its own unregistered runner with an injected computation,
  so nothing here touches the database except the fallback test at the end.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.PostAnalytics.TwelveMonthsRunner

  @step %{key: :posts, ms: 1, count: 7}

  # Runs, crashes and broadcasts cross three processes, and under a full
  # parallel suite that outlasts `assert_receive`'s 100 ms default.
  @wait 2_000

  # A computation that reports one step, then waits for the test to release it,
  # so a test can look at the runner while a run is in flight.
  defp gated_compute(test_pid) do
    fn opts ->
      send(test_pid, {:started, self()})
      opts[:progress].(@step)

      receive do
        :release -> %{reach: %{known: 42}, steps: [@step]}
        :crash -> raise "the database went away"
      end
    end
  end

  defp start_runner(opts) do
    topic = "reach_test:#{System.unique_integer([:positive])}"
    opts = Keyword.merge([name: nil, topic: topic], opts)
    pid = start_supervised!({TwelveMonthsRunner, opts})
    %{pid: pid, topic: topic}
  end

  defp release(signal \\ :release) do
    assert_receive {:started, task}, @wait
    send(task, signal)
    task
  end

  test "two watchers share one run and both hear its steps" do
    %{pid: runner} = start_runner(compute: gated_compute(self()))

    assert %{result: nil, running?: true} = TwelveMonthsRunner.watch(runner)
    other = Task.async(fn -> TwelveMonthsRunner.watch(runner) end)
    assert %{result: nil, running?: true, steps: steps} = Task.await(other)

    assert_receive {:reach, {:step, @step}}, @wait
    release()
    assert_receive {:reach, {:done, %{reach: %{known: 42}}}}, @wait
    # The second watch joined the first run instead of starting its own.
    refute_receive {:started, _task}, 100
    assert steps in [[], [@step]]
  end

  test "serves a fresh result without computing again" do
    %{pid: runner} = start_runner(compute: gated_compute(self()))

    TwelveMonthsRunner.watch(runner)
    release()
    assert_receive {:reach, {:done, _result}}, @wait

    assert %{result: %{reach: %{known: 42}}, running?: false} = TwelveMonthsRunner.watch(runner)
    refute_receive {:started, _task}, 50
  end

  test "keeps showing a stale result while it computes the next one" do
    %{pid: runner} = start_runner(compute: gated_compute(self()), ttl: 0)

    TwelveMonthsRunner.watch(runner)
    release()
    assert_receive {:reach, {:done, _result}}, @wait

    assert %{result: %{reach: %{known: 42}}, running?: true} = TwelveMonthsRunner.watch(runner)
    release()
    assert_receive {:reach, {:done, _result}}, @wait
  end

  @tag capture_log: true
  test "a failed run is reported and the next watch tries again" do
    %{pid: runner} = start_runner(compute: gated_compute(self()))

    TwelveMonthsRunner.watch(runner)
    release(:crash)
    assert_receive {:reach, :failed}, @wait
    assert %{result: nil, running?: true} = TwelveMonthsRunner.watch(runner)
    release()
    assert_receive {:reach, {:done, _result}}, @wait
  end

  test "peek never starts a run" do
    %{pid: runner} = start_runner(compute: gated_compute(self()))

    assert %{result: nil, running?: false, steps: []} = TwelveMonthsRunner.peek(runner)
    refute_receive {:started, _task}, 50
  end

  test "fetch waits for the run in flight" do
    %{pid: runner} = start_runner(compute: gated_compute(self()))

    fetch = Task.async(fn -> TwelveMonthsRunner.fetch(runner) end)
    release()

    assert %{reach: %{known: 42}} = Task.await(fetch)
  end

  test "without a runner there is nothing to watch and fetch computes in place" do
    assert TwelveMonthsRunner.watch(:no_such_runner) == :no_runner
    assert %{result: nil, running?: false} = TwelveMonthsRunner.peek(:no_such_runner)
    assert %{reach: %{known: 0}, posts: 0} = TwelveMonthsRunner.fetch(:no_such_runner)
  end
end
