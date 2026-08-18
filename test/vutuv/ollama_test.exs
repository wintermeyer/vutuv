defmodule Vutuv.OllamaTest do
  @moduledoc """
  How `:ollama_url` is read (issue #1573). One list, two jobs: a priority list
  for a single call — first instance first, service failures falling through
  to the fallback of record — and a pool for concurrent ones, so a second GPU
  box takes work instead of waiting for the first to break.

  The load-bearing assertion is that the pool stops before the **last** entry
  unless an operator says otherwise: vutuv.de's list ends in the web server's
  own CPU Ollama, and spreading onto that would be a regression dressed as a
  feature. So a two-entry list still sends every call to the first instance,
  and a three-entry one spreads over the first two.

  All against a `plug:` stub — no live Ollama.
  """
  use ExUnit.Case, async: false

  alias Vutuv.Ollama

  @req_options_key :ollama_endpoint_test_req_options

  setup do
    # A GPU pair plus the patient local fallback: two workers, one reserve.
    put_config(:ollama_url, "http://fast.test:11434, http://second.test:11434, http://local.test")
    on_exit(fn -> Application.delete_env(:vutuv, @req_options_key) end)
    :ok
  end

  defp put_config(key, value) do
    previous = Application.fetch_env(:vutuv, key)
    Application.put_env(:vutuv, key, value)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:vutuv, key, value)
        :error -> Application.delete_env(:vutuv, key)
      end
    end)
  end

  defp stub(fun), do: Application.put_env(:vutuv, @req_options_key, plug: fun)

  defp answer(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"message" => %{"content" => "ok"}}))
  end

  defp call, do: Ollama.post("/api/chat", %{}, req_options_key: @req_options_key)

  # Reports which instance it landed on and then holds the request open until
  # the test releases it, which is how a call is kept genuinely in flight.
  defp holding_stub do
    parent = self()

    stub(fn conn ->
      send(parent, {:hit, conn.host, self()})

      receive do
        :release -> answer(conn)
      after
        5_000 -> answer(conn)
      end
    end)
  end

  describe "urls/0 and concurrency/0" do
    test "the list is trimmed, and everything but the fallback is a worker" do
      assert Ollama.urls() == [
               "http://fast.test:11434",
               "http://second.test:11434",
               "http://local.test"
             ]

      assert Ollama.concurrency() == 2
    end

    test "one instance is one call at a time" do
      put_config(:ollama_url, "http://only.test:11434/")
      assert Ollama.urls() == ["http://only.test:11434"]
      assert Ollama.concurrency() == 1
    end

    test "a GPU box plus a local fallback is one worker, exactly as before" do
      put_config(:ollama_url, "http://gpu.test:11434,http://localhost:11434")
      assert Ollama.concurrency() == 1
    end

    test ":ollama_concurrency overrides it — a list that is all GPUs and no reserve" do
      put_config(:ollama_url, "http://gpu1.test:11434,http://gpu2.test:11434")
      assert Ollama.concurrency() == 1

      put_config(:ollama_concurrency, 2)
      assert Ollama.concurrency() == 2
    end
  end

  describe "one call at a time" do
    test "starts on the first instance, and the next call does too" do
      parent = self()
      stub(fn conn -> send(parent, {:hit, conn.host, nil}) && answer(conn) end)

      assert {:ok, _} = call()
      assert {:ok, _} = call()

      assert_received {:hit, "fast.test", nil}
      assert_received {:hit, "fast.test", nil}
      refute_received {:hit, _other, nil}
    end

    test "a failing instance still falls through in priority order" do
      parent = self()

      stub(fn conn ->
        send(parent, {:hit, conn.host, nil})

        case conn.host do
          "local.test" -> answer(conn)
          _down -> Plug.Conn.send_resp(conn, 503, "gpu busy")
        end
      end)

      assert {:ok, _} = call()
      assert_received {:hit, "fast.test", nil}
      assert_received {:hit, "second.test", nil}
      assert_received {:hit, "local.test", nil}
    end

    test "every instance down is one service error carrying the last reason" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 500, "") end)
      assert {:error, {:service, {:http, 500}}} = call()
    end
  end

  describe "concurrent calls" do
    test "the second call takes the second worker instead of queueing" do
      holding_stub()

      first = Task.async(&call/0)
      # Wait for the first call to be inside the model before starting the
      # second: the point is what a call does while another one is running,
      # not which of two racing claims wins.
      assert_receive {:hit, first_host, first_plug}, 2_000

      second = Task.async(&call/0)
      assert_receive {:hit, second_host, second_plug}, 2_000

      assert first_host == "fast.test"
      assert second_host == "second.test"

      send(first_plug, :release)
      send(second_plug, :release)
      assert [{:ok, _}, {:ok, _}] = Task.await_many([first, second])
    end

    test "the fallback of record is not a worker — a third call doubles up on a GPU" do
      holding_stub()

      calls =
        for _ <- 1..3 do
          task = Task.async(&call/0)
          assert_receive {:hit, host, plug}, 2_000
          {task, host, plug}
        end

      # Every worker busy means the next call doubles up on one of them, never
      # local.test: that entry is in the list to keep the feature alive while
      # the GPUs are down, not to take a third of the work. The bound on how
      # many calls are in flight belongs to the caller (`concurrency/0`), not
      # to a queue in here.
      assert Enum.map(calls, fn {_task, host, _plug} -> host end) ==
               ["fast.test", "second.test", "fast.test"]

      for {_task, _host, plug} <- calls, do: send(plug, :release)
      assert [{:ok, _}, {:ok, _}, {:ok, _}] = calls |> Enum.map(&elem(&1, 0)) |> Task.await_many()
    end

    test "an instance is free again once its call returns" do
      holding_stub()

      first = Task.async(&call/0)
      assert_receive {:hit, "fast.test", first_plug}, 2_000
      send(first_plug, :release)
      assert {:ok, _} = Task.await(first)

      # Nothing in flight any more, so the priority list applies again.
      second = Task.async(&call/0)
      assert_receive {:hit, "fast.test", second_plug}, 2_000
      send(second_plug, :release)
      assert {:ok, _} = Task.await(second)
    end
  end
end
