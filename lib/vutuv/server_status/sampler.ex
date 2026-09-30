defmodule Vutuv.ServerStatus.Sampler do
  @moduledoc """
  Reads every configured server on a timer and publishes one reading per
  server into an ETS table (`Vutuv.ServerStatus.snapshot/0`), the only thing
  `/system/status` reads.

  CPU load is a counter, so a percentage needs two readings: the sampler keeps
  the previous raw reading of each server and reports the share of the time in
  between that was busy. The first reading therefore has no percentage, and
  the second follows a second later instead of a whole interval, so a freshly
  started server shows numbers almost at once.

  The history behind the sparklines lives in this process and nowhere else. A
  deploy starts it empty and it refills within one sparkline's width; nothing
  is lost that anybody needs, which is why it is not worth a table.

  Every source is read in its own task with a deadline, so one server that
  does not answer shows as unreachable instead of holding up the others.
  """

  use GenServer

  alias Vutuv.ServerStatus
  alias Vutuv.ServerStatus.Local
  alias Vutuv.ServerStatus.Remote

  @read_timeout 8_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Takes one reading of every server now and waits for it (tests)."
  def sample_now, do: GenServer.call(__MODULE__, :sample, @read_timeout * 2)

  @impl true
  def init(opts) do
    if Keyword.has_key?(opts, :sources) or ServerStatus.enabled?() do
      :ets.new(ServerStatus.table(), [:named_table, :protected, read_concurrency: true])

      state = %{
        sources: Keyword.get_lazy(opts, :sources, &ServerStatus.sources/0),
        interval: Keyword.get_lazy(opts, :interval, &ServerStatus.interval/0),
        previous: %{},
        cpu_history: %{},
        gpu_history: %{}
      }

      if state.interval != :manual, do: send(self(), :first_sample)
      {:ok, state}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:first_sample, state) do
    Process.send_after(self(), :sample, 1_000)
    {:noreply, sample(state)}
  end

  def handle_info(:sample, state) do
    Process.send_after(self(), :sample, state.interval)
    {:noreply, sample(state)}
  end

  @impl true
  def handle_call(:sample, _from, state), do: {:reply, :ok, sample(state)}

  defp sample(state) do
    raws =
      state.sources
      |> Task.async_stream(&read/1, timeout: @read_timeout, on_timeout: :kill_task, ordered: true)
      |> Enum.map(fn
        {:ok, raw} -> raw
        {:exit, _} -> nil
      end)

    {servers, state} =
      state.sources
      |> Enum.zip(raws)
      |> Enum.map_reduce(state, fn {source, raw}, acc -> reading(source.number, raw, acc) end)

    :ets.insert(ServerStatus.table(), {:servers, servers})
    state
  end

  # The graphics cards are read beside the machine rather than after it, so a
  # slow GPU exporter cannot push a reading that already arrived past the
  # deadline and turn the whole server "unreachable".
  defp read(source) do
    gpus = Task.async(fn -> Remote.read_gpus(source.gpu_url) end)
    raw = read_node(source)
    gpus = Task.await(gpus, @read_timeout)
    raw && Map.put(raw, :gpus, gpus)
  end

  defp read_node(%{kind: :local} = source),
    do: source |> Map.take([:root, :df]) |> Map.to_list() |> Local.read()

  defp read_node(%{kind: :remote, node_url: url}), do: Remote.read_node(url)

  defp reading(number, nil, state) do
    {%{number: number, reachable?: false},
     %{state | previous: Map.delete(state.previous, number)}}
  end

  defp reading(number, raw, state) do
    previous = Map.get(state.previous, number)
    cpu = previous && percent(previous.cpu_times, raw.cpu_times)
    cpu_history = remember(state.cpu_history, number, cpu)

    {gpus, gpu_history} =
      Enum.map_reduce(raw.gpus, state.gpu_history, fn gpu, history ->
        history = remember(history, {number, gpu.id}, gpu.utilization)
        {Map.put(gpu, :history, Map.get(history, {number, gpu.id}, [])), history}
      end)

    server = %{
      number: number,
      reachable?: true,
      cpu_model: raw.cpu_model,
      cores: raw.cores,
      cpu: cpu,
      per_core: per_core(previous, raw),
      cpu_history: Map.get(cpu_history, number, []),
      load: raw.load,
      mem_total: raw.mem_total,
      mem_used: raw.mem_total && raw.mem_available && raw.mem_total - raw.mem_available,
      disk: raw.disk,
      booted_at: raw.booted_at,
      os: raw.os,
      gpus: gpus
    }

    {server,
     %{
       state
       | previous: Map.put(state.previous, number, raw),
         cpu_history: cpu_history,
         gpu_history: gpu_history
     }}
  end

  defp per_core(nil, _raw), do: []

  defp per_core(previous, raw) do
    with %{per_core: before} <- previous.cpu_times,
         %{per_core: now} <- raw.cpu_times,
         true <- length(before) == length(now) do
      before |> Enum.zip(now) |> Enum.map(fn {a, b} -> share(a, b) end)
    else
      _ -> []
    end
  end

  defp percent(%{total: before}, %{total: now}), do: share(before, now)
  defp percent(_before, _now), do: nil

  defp share({busy_before, total_before}, {busy_now, total_now}) do
    elapsed = total_now - total_before
    if elapsed > 0, do: (100 * (busy_now - busy_before) / elapsed) |> max(0.0) |> min(100.0)
  end

  defp remember(history, _key, nil), do: history

  defp remember(history, key, value) do
    Map.update(history, key, [value], &Enum.take(&1 ++ [value], -ServerStatus.history_length()))
  end
end
