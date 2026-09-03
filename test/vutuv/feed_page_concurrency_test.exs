defmodule Vutuv.FeedPageConcurrencyTest do
  @moduledoc """
  The feed's sources are fetched concurrently (`Vutuv.FeedPage.fetch_sources/3`)
  because running ten independent reads one after the other only added their
  latencies up — 31 ms of the newsfeed's 45 ms dead render, measured on a copy
  of production.

  What that buys is latency; what it must not cost is a single row, a single
  place in the order, or the ability of a source to fail loudly. Those three are
  what this file pins, plus the one thing about a `Task` that would break a
  source silently: it does not inherit the caller's process dictionary, which is
  where the viewer's clock lives (`Vutuv.ViewerClock`).

  Sources here are plain functions rather than real queries — the point is the
  fetching rule, not what any particular source selects.
  """
  use ExUnit.Case, async: true

  alias Vutuv.FeedPage

  defp at(minutes_ago) do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.add(-minutes_ago * 60)
  end

  # A source that answers with the items it was built from, ignoring the cursor.
  defp source(items), do: fn _fetch_n, _cursor -> items end

  describe "fetching the sources" do
    test "every source's rows come back, and in the order the sources were listed" do
      sources = for n <- 1..10, do: source([%{id: "s#{n}", at: at(n)}])

      assert FeedPage.fetch_sources(sources, 5, nil) ==
               Enum.map(1..10, &[%{id: "s#{&1}", at: at(&1)}])
    end

    test "more sources than may run at once still all run" do
      # Deliberately past the concurrency cap, so the stream has to work through
      # several waves rather than one.
      sources = for n <- 1..40, do: source([%{id: "s#{n}", at: at(1)}])

      assert length(FeedPage.fetch_sources(sources, 5, nil)) == 40
    end

    test "a source that raises brings the fetch down rather than returning short" do
      # The failure mode to avoid is a page that silently loses one source's
      # rows: an exception in a task must reach the caller, not be swallowed
      # into a shorter feed nobody can tell from a quiet day.
      sources = [source([%{id: "a", at: at(1)}]), fn _n, _c -> raise "source down" end]

      # In its own unlinked process, or the exit takes the test with it — which
      # is itself the assertion: the failure travels out of the task.
      {pid, ref} = spawn_monitor(fn -> FeedPage.fetch_sources(sources, 5, nil) end)

      # Generously, because the default 100 ms is a bet on scheduling: the whole
      # suite runs twenty cases at once, and this failed there while passing
      # alone. What is asserted is that the exit arrives at all, not how quickly.
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5_000
      assert {%RuntimeError{message: "source down"}, _stacktrace} = reason
    end

    test "each source is handed the fetch size and the cursor the caller passed" do
      cursor = %{at: at(5), ids: ["x"], since: nil}
      spy = fn fetch_n, c -> [%{id: "#{fetch_n}/#{inspect(c.ids)}", at: at(1)}] end

      assert [[%{id: "7/[\"x\"]"}]] = FeedPage.fetch_sources([spy], 7, cursor)
    end
  end

  describe "paginate/3 over concurrent sources" do
    test "merges newest first across sources and reports the next page" do
      sources = [
        source([%{id: "a", at: at(1)}, %{id: "d", at: at(4)}]),
        source([%{id: "b", at: at(2)}, %{id: "e", at: at(5)}]),
        source([%{id: "c", at: at(3)}])
      ]

      assert %{entries: entries, more?: true} = FeedPage.paginate(sources, 3, nil)
      assert Enum.map(entries, & &1.id) == ~w(a b c)
    end

    test "items tying at the same second keep the source order they were listed in" do
      # `Enum.sort_by/3` is stable, so a tie falls back to the order the fetch
      # handed over — which is the order of the source list, and stays that way
      # only because the fetch keeps its results ordered.
      same = at(3)

      sources = [
        source([%{id: "first", at: same}]),
        source([%{id: "second", at: same}]),
        source([%{id: "third", at: same}])
      ]

      assert %{entries: entries} = FeedPage.paginate(sources, 3, nil)
      assert Enum.map(entries, & &1.id) == ~w(first second third)
    end
  end

  describe "the viewer's clock" do
    test "is read by the caller, never inside a source" do
      # A `Task` starts with an empty process dictionary, so a source that asked
      # `Vutuv.ViewerClock` for the viewer's zone would quietly get the
      # installation default instead — a feed grouped into the wrong days for
      # everybody outside it, with nothing raising. No source does today; this
      # is what says so out loud.
      Vutuv.ViewerClock.put_viewer(%{time_zone: "Pacific/Auckland", date_region: "de"})
      assert Vutuv.ViewerClock.zone() == "Pacific/Auckland"

      [[seen]] =
        FeedPage.fetch_sources(
          [fn _n, _c -> [%{id: Vutuv.ViewerClock.zone(), at: at(1)}] end],
          5,
          nil
        )

      assert seen.id != "Pacific/Auckland",
             "a source now reads the viewer clock; it must be read in the caller and passed in"
    end
  end
end
