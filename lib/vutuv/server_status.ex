defmodule Vutuv.ServerStatus do
  @moduledoc """
  How the servers behind this installation are doing, for the public page at
  `/system/status`: processor, memory, disks, uptime and graphics cards, one
  card per machine.

  Two kinds of source, both producing the same raw reading
  (`Vutuv.ServerStatus.Local`, `Vutuv.ServerStatus.Remote`):

    * **this machine**, read straight from `/proc` and `df`, so an installation
      on one server gets a working page with no setup at all;
    * **another machine**, read from its Prometheus `node_exporter` (and an
      `nvidia_gpu_exporter` for its graphics cards) over the internal network.

  `Vutuv.ServerStatus.Sampler` reads every source on a timer, turns counter
  pairs into percentages and keeps a short history for the sparklines; the
  LiveView only reads the table it writes, so a hundred open pages cost the
  servers exactly what one does.

  **Servers are named by number, never by host.** The page is public, and a
  host name or an internal address points an attacker at the machine; so is a
  mount point, which is why disks are added up per server rather than listed.
  The order in `:hosts` is the numbering, and the token `"local"` marks where
  this machine sits in it, so "Server 2" can be the one the app runs on.

  Configuration (`config :vutuv, :server_status`, env in `config/runtime.exs`):

    * `:hosts` — the servers in page order: `"local"`, a host (`10.0.0.3`,
      node_exporter on 9100), a `host:port`, or a full URL of the metrics page.
    * `:gpu_hosts` — the hosts that also run an `nvidia_gpu_exporter` (9835 by
      default); each attaches to the server with the same host, and
      `localhost` / `127.0.0.1` attach to `"local"`.
    * `:interval` — milliseconds between two readings.

  `:server_status_enabled` switches the page, its footer link and the sampler
  off together.
  """

  @table :server_status
  @history_length 90
  @node_port 9100
  @gpu_port 9835
  @local_aliases ~w(local localhost 127.0.0.1 ::1)

  @doc "Whether the status page (and its footer link) exists on this installation."
  def enabled?, do: Application.get_env(:vutuv, :server_status_enabled, true)

  @doc "The ETS table the sampler writes and the page reads."
  def table, do: @table

  @doc "How many readings a sparkline shows (the last 15 minutes at the default interval)."
  def history_length, do: @history_length

  @doc "Milliseconds between two readings."
  def interval, do: Keyword.get(config(), :interval, :timer.seconds(10))

  @doc """
  The latest reading of every server, in page order. Empty until the sampler
  has run once, or when it is not running at all.
  """
  def snapshot do
    case :ets.lookup(@table, :servers) do
      [{:servers, servers}] -> servers
      [] -> []
    end
  rescue
    ArgumentError -> []
  end

  @doc """
  The configured servers as sources for the sampler, numbered in the order
  `hosts` lists them. Takes the configuration as an argument so it can be
  checked without touching the application env.
  """
  def sources(opts \\ config()) do
    gpu_urls =
      opts
      |> Keyword.get(:gpu_hosts, [])
      |> Map.new(fn entry -> {host_key(entry), url(entry, @gpu_port)} end)

    opts
    |> Keyword.get(:hosts, ["local"])
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, number} ->
      key = host_key(entry)
      source = %{number: number, gpu_url: Map.get(gpu_urls, key)}

      if key == :local,
        do: Map.put(source, :kind, :local),
        else: Map.merge(source, %{kind: :remote, node_url: url(entry, @node_port)})
    end)
  end

  @doc """
  One server's disks as a single figure, from `{used, available}` bytes per
  device: capacity is used plus available, the way df reckons its percentage,
  so the root reserve does not read as free space. `nil` without a disk.
  """
  def disk_total([]), do: nil

  def disk_total(devices) do
    used = devices |> Enum.map(&elem(&1, 0)) |> Enum.sum()
    available = devices |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    %{used: round(used), total: round(used + available)}
  end

  defp config, do: Application.get_env(:vutuv, :server_status, [])

  # The key a host and its GPU exporter are matched by: the bare host, and one
  # shared key for every spelling of this machine.
  defp host_key(entry) do
    host = entry |> with_scheme() |> URI.parse() |> Map.get(:host)
    if entry in @local_aliases or host in @local_aliases, do: :local, else: host
  end

  defp url(entry, default_port) do
    cond do
      String.contains?(entry, "://") -> entry
      entry in @local_aliases -> "http://127.0.0.1:#{default_port}/metrics"
      String.contains?(entry, ":") -> "http://#{entry}/metrics"
      true -> "http://#{entry}:#{default_port}/metrics"
    end
  end

  defp with_scheme(entry),
    do: if(String.contains?(entry, "://"), do: entry, else: "http://" <> entry)
end
