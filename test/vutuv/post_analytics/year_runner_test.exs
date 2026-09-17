defmodule Vutuv.PostAnalytics.YearRunnerTest do
  @moduledoc """
  The background owner of the investor page's yearly reach
  (`Vutuv.PostAnalytics.YearRunner`): one run at a time however many people
  watch, its steps broadcast as they finish, the result kept for a while, and a
  failed run reported rather than left spinning.

  Each test starts its own unregistered runner with an injected computation,
  so nothing here touches the database except the fallback test at the end.
  """
  use Vutuv.DataCase, async: true

  alias Vutuv.PostAnalytics.YearRunner

  @step %{key: :posts, ms: 1, count: 7}

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
    topic = "year_reach_test:#{System.unique_integer([:positive])}"
    opts = Keyword.merge([name: nil, topic: topic], opts)
    pid = start_supervised!({YearRunner, opts})
    %{pid: pid, topic: topic}
  end

  defp release(signal \\ :release) do
    assert_receive {:started, task}
    send(task, signal)
    task
  end

  test "two watchers share one run and both hear its steps" do
    %{pid: runner} = start_runner(compute: gated_compute(self()))

    assert %{result: nil, running?: true} = YearRunner.watch(runner)
    other = Task.async(fn -> YearRunner.watch(runner) end)
    assert %{result: nil, running?: true, steps: steps} = Task.await(other)

    assert_receive {:year_reach, {:step, @step}}
    release()
    assert_receive {:year_reach, {:done, %{reach: %{known: 42}}}}
    # The second watch joined the first run instead of starting its own.
    refute_receive {:started, _task}, 100
    assert steps in [[], [@step]]
  end

  test "serves a fresh result without computing again" do
    %{pid: runner} = start_runner(compute: gated_compute(self()))

    YearRunner.watch(runner)
    release()
    assert_receive {:year_reach, {:done, _result}}

    assert %{result: %{reach: %{known: 42}}, running?: false} = YearRunner.watch(runner)
    refute_receive {:started, _task}, 50
  end

  test "keeps showing a stale result while it computes the next one" do
    %{pid: runner} = start_runner(compute: gated_compute(self()), ttl: 0)

    YearRunner.watch(runner)
    release()
    assert_receive {:year_reach, {:done, _result}}

    assert %{result: %{reach: %{known: 42}}, running?: true} = YearRunner.watch(runner)
    release()
    assert_receive {:year_reach, {:done, _result}}
  end

  @tag capture_log: true
  test "a failed run is reported and the next watch tries again" do
    %{pid: runner} = start_runner(compute: gated_compute(self()))

    YearRunner.watch(runner)
    release(:crash)
    assert_receive {:year_reach, :failed}
    assert %{result: nil, running?: true} = YearRunner.watch(runner)
    release()
    assert_receive {:year_reach, {:done, _result}}
  end

  test "peek never starts a run" do
    %{pid: runner} = start_runner(compute: gated_compute(self()))

    assert %{result: nil, running?: false, steps: []} = YearRunner.peek(runner)
    refute_receive {:started, _task}, 50
  end

  test "fetch waits for the run in flight" do
    %{pid: runner} = start_runner(compute: gated_compute(self()))

    fetch = Task.async(fn -> YearRunner.fetch(runner) end)
    release()

    assert %{reach: %{known: 42}} = Task.await(fetch)
  end

  test "without a runner there is nothing to watch and fetch computes in place" do
    assert YearRunner.watch(:no_such_runner) == :no_runner
    assert %{result: nil, running?: false} = YearRunner.peek(:no_such_runner)
    assert %{reach: %{known: 0}, posts: 0} = YearRunner.fetch(:no_such_runner)
  end
end
