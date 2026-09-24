defmodule Vutuv.Activity.LikeThrottleTest do
  use ExUnit.Case, async: true

  alias Vutuv.Activity.LikeThrottle

  test "the first ten likes are announced one by one" do
    for n <- 1..10, do: assert(LikeThrottle.decide(n, 50) == :single)
  end

  test "after that only the jumps, and the cap closes with a final notice" do
    announced =
      for n <- 11..200, LikeThrottle.decide(n, 50) != :quiet, do: {n, LikeThrottle.decide(n, 50)}

    assert announced == [{25, {:milestone, 25}}, {50, {:final, 50}}]
  end

  test "a cap between two jumps still gets its final notice" do
    assert LikeThrottle.decide(25, 100) == {:milestone, 25}
    assert LikeThrottle.decide(100, 100) == {:final, 100}
    assert LikeThrottle.decide(101, 100) == :quiet
  end

  test "without a cap the jumps go on an order of magnitude at a time" do
    announced = for n <- 11..30_000, LikeThrottle.decide(n, nil) != :quiet, do: n

    assert announced == [25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 25_000]
  end
end
