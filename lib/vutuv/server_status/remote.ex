defmodule Vutuv.ServerStatus.Remote do
  @moduledoc """
  A raw reading of another machine, from the text page of its Prometheus
  `node_exporter`, plus its graphics cards from an `nvidia_gpu_exporter`.

  Produces the same shape as `Vutuv.ServerStatus.Local`. Deliberately reads
  nothing that names the machine (`node_uname_info`'s nodename, the mount
  points): the page it feeds is public.

  The requests go to hosts the operator listed in `SERVER_STATUS_HOSTS` and
  nowhere else, so an installation that lists none makes no outbound call at
  all. Tests stub them through `:server_status_req_options`.
  """

  require Logger

  alias Vutuv.ServerStatus

  @timeout 4_000

  # File systems that are not a disk, or not one worth adding up.
  @virtual_fstypes ~w(tmpfs devtmpfs overlay squashfs ramfs nsfs autofs fuse.lxcfs)

  @doc "Fetches and parses a node_exporter page; `nil` when it does not answer."
  def read_node(url) do
    case fetch(url) do
      {:ok, text} -> parse_node(text)
      _ -> nil
    end
  end

  @doc "Fetches and parses a GPU exporter page; `[]` when it does not answer."
  def read_gpus(nil), do: []

  def read_gpus(url) do
    case fetch(url) do
      {:ok, text} -> parse_gpus(text)
      _ -> []
    end
  end

  defp fetch(url) do
    options =
      Keyword.merge(
        [
          retry: false,
          receive_timeout: @timeout,
          connect_options: [timeout: @timeout],
          decode_body: false
        ],
        Application.get_env(:vutuv, :server_status_req_options, [])
      )

    case Req.get(url, options) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      other ->
        Logger.debug(fn ->
          "server status: #{url} did not answer: #{inspect(other, limit: 5)}"
        end)

        :error
    end
  rescue
    error -> {:error, error}
  end

  @node_metrics ~w(node_cpu_info node_cpu_seconds_total node_load1 node_load5 node_load15
                   node_memory_MemTotal_bytes node_memory_MemAvailable_bytes node_boot_time_seconds
                   node_os_info node_filesystem_size_bytes node_filesystem_free_bytes
                   node_filesystem_avail_bytes)

  @gpu_metrics ~w(nvidia_smi_gpu_info nvidia_smi_utilization_gpu_ratio nvidia_smi_memory_used_bytes
                  nvidia_smi_memory_total_bytes nvidia_smi_temperature_gpu nvidia_smi_power_draw_watts
                  nvidia_smi_enforced_power_limit_watts)

  @doc "The raw reading out of a node_exporter page."
  def parse_node(text) do
    metrics = parse(text, @node_metrics)
    first = fn name -> List.first(metrics[name] || [], {%{}, nil}) end
    value = fn name -> name |> first.() |> elem(1) end
    label = fn name, key -> name |> first.() |> elem(0) |> Map.get(key) end

    per_core = cpu_times(metrics["node_cpu_seconds_total"] || [])

    %{
      cpu_model: label.("node_cpu_info", "model_name"),
      cores: length(per_core),
      cpu_times:
        if(per_core == [], do: nil, else: %{total: sum_pairs(per_core), per_core: per_core}),
      load: load(value.("node_load1"), value.("node_load5"), value.("node_load15")),
      mem_total: round_or_nil(value.("node_memory_MemTotal_bytes")),
      mem_available: round_or_nil(value.("node_memory_MemAvailable_bytes")),
      booted_at: round_or_nil(value.("node_boot_time_seconds")),
      os: label.("node_os_info", "pretty_name"),
      disk: disk(metrics)
    }
  end

  @doc "Every graphics card on an nvidia_gpu_exporter page."
  def parse_gpus(text) do
    metrics = parse(text, @gpu_metrics)

    by_card =
      for {name, samples} <- metrics,
          {labels, value} <- samples,
          into: %{},
          do: {{name, labels["uuid"]}, value}

    for {labels, _} <- metrics["nvidia_smi_gpu_info"] || [] do
      id = labels["uuid"]
      utilization = by_card[{"nvidia_smi_utilization_gpu_ratio", id}]

      %{
        id: id,
        name: labels["name"],
        utilization: utilization && utilization * 100,
        mem_used: round_or_nil(by_card[{"nvidia_smi_memory_used_bytes", id}]),
        mem_total: round_or_nil(by_card[{"nvidia_smi_memory_total_bytes", id}]),
        temperature: by_card[{"nvidia_smi_temperature_gpu", id}],
        power: by_card[{"nvidia_smi_power_draw_watts", id}],
        power_limit: by_card[{"nvidia_smi_enforced_power_limit_watts", id}]
      }
    end
  end

  # node_cpu_seconds_total per core and mode -> one {busy, total} pair per
  # core, in core order. Idle is idle plus iowait, as in /proc/stat.
  defp cpu_times(samples) do
    samples
    |> Enum.group_by(fn {labels, _} -> String.to_integer(labels["cpu"]) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_cpu, modes} ->
      total = modes |> Enum.map(&elem(&1, 1)) |> Enum.sum()
      idle = for({labels, v} <- modes, labels["mode"] in ~w(idle iowait), do: v) |> Enum.sum()
      {total - idle, total}
    end)
  end

  defp sum_pairs(pairs) do
    Enum.reduce(pairs, {0.0, 0.0}, fn {busy, total}, {b, t} -> {b + busy, t + total} end)
  end

  defp load(one, five, fifteen) when is_number(one) and is_number(five) and is_number(fifteen),
    do: {one, five, fifteen}

  defp load(_, _, _), do: nil

  # Used is size minus free (the root reserve counts as used, as in df);
  # capacity is used plus available. Each device once: a bind mount is the same
  # disk again.
  defp disk(metrics) do
    by = fn name ->
      for {labels, value} <- metrics[name] || [],
          String.starts_with?(labels["device"] || "", "/dev/"),
          labels["fstype"] not in @virtual_fstypes,
          into: %{},
          do: {labels["device"], value}
    end

    size = by.("node_filesystem_size_bytes")
    free = by.("node_filesystem_free_bytes")
    avail = by.("node_filesystem_avail_bytes")

    for device <- Map.keys(size), Map.has_key?(free, device), Map.has_key?(avail, device) do
      {size[device] - free[device], avail[device]}
    end
    |> ServerStatus.disk_total()
  end

  defp round_or_nil(nil), do: nil
  defp round_or_nil(value), do: round(value)

  @doc """
  The Prometheus text format as `%{name => [{labels, value}]}`, for the
  metric names asked for only. A node_exporter page runs to a couple of
  thousand lines and a card needs a dozen metrics, so everything else is
  dropped on a prefix check before any regex runs. Comments and lines that
  do not parse are skipped: a reading with a metric missing is still a
  reading.
  """
  def parse(text, names) do
    wanted = MapSet.new(names)

    text
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, names))
    |> Enum.map(&parse_line/1)
    |> Enum.filter(fn sample -> sample != nil and MapSet.member?(wanted, elem(sample, 0)) end)
    |> Enum.group_by(&elem(&1, 0), fn {_name, labels, value} -> {labels, value} end)
  end

  # A line without labels leaves the middle group empty, which parses to %{}.
  # `NaN` and `+Inf` are not numbers Float.parse knows, so they drop out.
  defp parse_line(line) do
    with [_, name, labels, value] <-
           Regex.run(~r/^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(.*)\})?\s+(\S+)/, line),
         {number, _} <- Float.parse(value) do
      {name, parse_labels(labels), number}
    else
      _ -> nil
    end
  end

  defp parse_labels(text) do
    ~r/([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\]|\\.)*)"/
    |> Regex.scan(text)
    |> Map.new(fn [_, key, value] -> {key, value} end)
  end
end
