defmodule Vutuv.PageScreenshot.BrowsersTest do
  @moduledoc """
  The cap on headless Chromiums running at once. Every capture path meets in
  `Vutuv.PageScreenshot.run/4`, and a path that starts a browser per request
  (a moderation case, once a link save) could otherwise start them until the
  host runs out of memory.
  """
  use ExUnit.Case, async: true

  alias Vutuv.PageScreenshot.Browsers

  defp start_browsers(limit) do
    name = :"browsers_test_#{System.unique_integer([:positive])}"
    start_supervised!({Browsers, name: name, limit: limit})
    name
  end

  # A run that holds its slot until the test says :go.
  defp hold_slot(server) do
    test = self()

    Task.async(fn ->
      Browsers.run(
        fn ->
          send(test, {:running, self()})

          receive do
            :go -> :done
          end
        end,
        server
      )
    end)
  end

  test "a run past the limit waits until a slot is free, then runs" do
    server = start_browsers(1)

    first = hold_slot(server)
    assert_receive {:running, first_pid}

    second = hold_slot(server)
    refute_receive {:running, _pid}, 100

    send(first_pid, :go)
    assert Task.await(first) == :done
    assert_receive {:running, second_pid}
    send(second_pid, :go)
    assert Task.await(second) == :done
  end

  # Two layers keep this promise, the `after` checkin and the monitor on the
  # caller, so neither alone turns it red.
  test "a run that crashes gives its slot back" do
    server = start_browsers(1)

    {pid, ref} = spawn_monitor(fn -> Browsers.run(fn -> raise "boom" end, server) end)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

    assert Browsers.run(fn -> :ran end, server) == :ran
  end

  test "a caller that dies while holding a slot gives it back" do
    server = start_browsers(1)
    test = self()

    holder =
      spawn(fn ->
        Browsers.run(
          fn ->
            send(test, :holding)

            receive do
              :never -> :ok
            end
          end,
          server
        )
      end)

    assert_receive :holding
    ref = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^ref, :process, ^holder, :killed}

    assert Browsers.run(fn -> :ran end, server) == :ran
  end

  test "the application runs one instance for every capture path" do
    assert Process.whereis(Browsers)
  end
end
