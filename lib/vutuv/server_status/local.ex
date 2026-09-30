defmodule Vutuv.ServerStatus.Local do
  @moduledoc """
  A raw reading of the machine this app runs on, from Linux's `/proc`, the
  `/etc/os-release` file and `df`. No exporter and no extra package, so a
  single-server installation gets its status page without any setup.

  Every field is `nil` where the file is missing, which is the whole of `/proc`
  on a developer's Mac: the page then shows what it has (cores, disks) rather
  than failing. `root` and `df` are options so the tests can read a fixture
  machine; nothing else passes them.

  The raw shape, shared with `Vutuv.ServerStatus.Remote`: CPU counters are
  `{busy, total}` pairs in whatever unit the source counts in, because only the
  difference between two readings means anything.
  """

  alias Vutuv.ServerStatus

  def read(opts \\ []) do
    root = Keyword.get(opts, :root, "/")
    df = Keyword.get(opts, :df, &run_df/0)
    cpu_times = cpu_times(file(root, "proc/stat"))
    meminfo = file(root, "proc/meminfo")

    %{
      cpu_model: cpu_model(file(root, "proc/cpuinfo")),
      cores: if(cpu_times, do: length(cpu_times.per_core), else: System.schedulers_online()),
      cpu_times: cpu_times,
      load: load(file(root, "proc/loadavg")),
      mem_total: meminfo(meminfo, "MemTotal"),
      mem_available: meminfo(meminfo, "MemAvailable"),
      booted_at: booted_at(file(root, "proc/uptime")),
      os: os_name(file(root, "etc/os-release")),
      disk: disk(df.())
    }
  end

  defp file(root, path) do
    case File.read(Path.join(root, path)) do
      {:ok, text} -> text
      {:error, _} -> nil
    end
  end

  # /proc/stat: "cpu" is the sum, "cpuN" one core each. Idle time is idle plus
  # iowait; the first eight fields are the whole of it (guest time is already
  # counted inside user).
  defp cpu_times(nil), do: nil

  defp cpu_times(text) do
    rows =
      for "cpu" <> _ = line <- String.split(text, "\n"),
          [name | fields] = String.split(line),
          do: {name, fields |> Enum.take(8) |> Enum.map(&String.to_integer/1)}

    case rows do
      [{"cpu", total} | cores] ->
        %{total: busy_total(total), per_core: Enum.map(cores, &busy_total(elem(&1, 1)))}

      _ ->
        nil
    end
  end

  defp busy_total([_user, _nice, _system, idle, iowait | _] = fields) do
    all = Enum.sum(fields)
    {all - idle - iowait, all}
  end

  defp cpu_model(nil), do: nil

  defp cpu_model(text) do
    Enum.find_value(String.split(text, "\n"), fn line ->
      case String.split(line, ":", parts: 2) do
        ["model name" <> _ = key, value] -> String.trim(key) == "model name" && String.trim(value)
        _ -> nil
      end
    end)
  end

  defp load(nil), do: nil

  defp load(text) do
    case String.split(text) do
      [one, five, fifteen | _] -> {float(one), float(five), float(fifteen)}
      _ -> nil
    end
  end

  # meminfo counts in kB (kibibytes, despite the label).
  defp meminfo(nil, _key), do: nil

  defp meminfo(text, key) do
    Enum.find_value(String.split(text, "\n"), fn line ->
      case String.split(line) do
        [^key <> ":", value | _] -> String.to_integer(value) * 1024
        _ -> nil
      end
    end)
  end

  defp booted_at(nil), do: nil

  defp booted_at(text) do
    [uptime | _] = String.split(text)
    System.os_time(:second) - trunc(float(uptime))
  end

  defp os_name(nil), do: nil

  defp os_name(text) do
    Enum.find_value(String.split(text, "\n"), fn
      "PRETTY_NAME=" <> value -> String.trim(value, "\"")
      _ -> nil
    end)
  end

  # `df -kP` on every mounted file system: the ones on a real device, each
  # device once however often it is mounted (a bind mount is the same disk
  # again). df counts in kibibytes.
  defp disk(output) do
    output
    |> String.split("\n")
    |> Enum.drop(1)
    |> Enum.map(&String.split/1)
    |> Enum.flat_map(fn
      ["/dev/" <> _ = device, _blocks, used, available | _] ->
        [{device, String.to_integer(used) * 1024, String.to_integer(available) * 1024}]

      _ ->
        []
    end)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.map(fn {_device, used, available} -> {used, available} end)
    |> ServerStatus.disk_total()
  end

  defp run_df do
    case System.cmd("df", ["-kP"], stderr_to_stdout: true) do
      {output, _status} -> output
    end
  rescue
    _ -> ""
  end

  defp float(text) do
    {value, _} = Float.parse(text)
    value
  end
end
