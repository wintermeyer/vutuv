defmodule Vutuv.ServerStatusTest do
  @moduledoc """
  The readings behind `/system/status`: what a server's own `/proc` and an
  exporter's text become, how the sampler turns two counter readings into a
  percentage, and which parts of the configuration name which server.

  async: false — the sampler owns a named ETS table and the exporter stub lives
  in the application env.
  """
  use ExUnit.Case, async: false

  alias Vutuv.ServerStatus
  alias Vutuv.ServerStatus.Local
  alias Vutuv.ServerStatus.Remote
  alias Vutuv.ServerStatus.Sampler

  import Vutuv.ServerStatusHelpers

  @df fixture("df.txt")
  @node fixture("node_exporter.prom")
  @gpu fixture("gpu_exporter.prom")

  describe "Local.read/1" do
    test "reads the processor, memory, load, uptime and system from /proc" do
      raw = Local.read(root: root(), df: fn -> @df end)

      assert raw.cpu_model == "AMD EPYC 7443P 24-Core Processor"
      assert raw.cores == 4
      assert raw.cpu_times.total == {5_000, 20_000}
      assert length(raw.cpu_times.per_core) == 4
      assert raw.load == {1.52, 1.21, 0.98}
      assert raw.mem_total == 16_384_000 * 1024
      assert raw.mem_available == 4_096_000 * 1024
      assert raw.os == "Debian GNU/Linux 12 (bookworm)"
      assert_in_delta raw.booted_at, System.os_time(:second) - 3_600_000, 2
    end

    test "adds every real disk up once, whatever it is mounted on" do
      raw = Local.read(root: root(), df: fn -> @df end)

      # The system disk is mounted twice and counts once; udev and tmpfs are
      # not disks at all.
      assert raw.disk == %{used: 2_500_006_000 * 1024, total: 4_500_524_288 * 1024}
    end

    test "a machine without /proc still answers with what it knows" do
      raw = Local.read(root: "/nonexistent", df: fn -> "" end)

      assert raw.cores > 0
      assert raw.cpu_times == nil
      assert raw.mem_total == nil
      assert raw.disk == nil
    end
  end

  describe "Remote.parse_node/1" do
    test "reads the same shape out of a node_exporter page" do
      raw = Remote.parse_node(@node)

      assert raw.cpu_model == "AMD Ryzen 9 7950X 16-Core Processor"
      assert raw.cores == 2
      assert raw.cpu_times.total == {300.0, 2_000.0}
      assert raw.load == {2.5, 2.0, 1.75}
      assert raw.mem_total == 64_000_000_000
      assert raw.mem_available == 48_000_000_000
      assert raw.booted_at == 1_700_000_000
      assert raw.os == "Ubuntu 24.04.1 LTS"
      # tmpfs is left out and the doubly mounted system disk counts once.
      assert raw.disk == %{used: 1_100_030_000_000, total: 1_800_530_000_000}
    end

    test "never carries the machine's own name" do
      refute inspect(Remote.parse_node(@node)) =~ "gpu-box"
    end
  end

  describe "Remote.parse_gpus/1" do
    test "reads every card with its load, memory, temperature and power" do
      [first, second] = Remote.parse_gpus(@gpu)

      assert first.name == "NVIDIA RTX A6000"
      assert first.id == "GPU-aaaa"
      assert_in_delta first.utilization, 63.0, 0.001
      assert first.mem_used == 12_884_901_888
      assert first.mem_total == 51_527_024_640
      assert first.temperature == 61.0
      assert first.power == 187.5
      assert first.power_limit == 300.0
      assert second.utilization == 0.0
    end

    test "an empty page is no cards" do
      assert Remote.parse_gpus("") == []
    end
  end

  describe "ServerStatus.sources/1" do
    test "names servers in the order they are listed, with local as this machine" do
      sources =
        ServerStatus.sources(
          hosts: ["10.0.0.1", "local", "10.0.0.3:9101"],
          gpu_hosts: ["10.0.0.3"]
        )

      assert [
               %{
                 number: 1,
                 kind: :remote,
                 node_url: "http://10.0.0.1:9100/metrics",
                 gpu_url: nil
               },
               %{number: 2, kind: :local, gpu_url: nil},
               %{
                 number: 3,
                 kind: :remote,
                 node_url: "http://10.0.0.3:9101/metrics",
                 gpu_url: "http://10.0.0.3:9835/metrics"
               }
             ] = sources
    end

    test "a GPU on this machine attaches to the local server" do
      assert [%{kind: :local, gpu_url: "http://127.0.0.1:9835/metrics"}] =
               ServerStatus.sources(hosts: ["local"], gpu_hosts: ["localhost"])
    end

    test "full URLs are taken as they are" do
      assert [%{node_url: "https://metrics.example/node"}] =
               ServerStatus.sources(hosts: ["https://metrics.example/node"], gpu_hosts: [])
    end
  end

  describe "Sampler" do
    setup do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      # Every answer scales the counters by the number of the request, so two
      # readings are 300 busy of 2000 seconds apart: 15 %.
      stub_exporters(fn page ->
        scale_cpu_counters(page, Agent.get_and_update(calls, &{&1 + 1, &1 + 1}))
      end)

      start_sampler!()
      :ok
    end

    test "turns two counter readings into a percentage, overall and per core" do
      Sampler.sample_now()
      Sampler.sample_now()

      [_local, gpu_server | _] = ServerStatus.snapshot()

      assert gpu_server.number == 2
      assert gpu_server.reachable?
      assert_in_delta gpu_server.cpu, 15.0, 0.01
      assert [c0, c1] = gpu_server.per_core
      assert_in_delta c0, 20.0, 0.01
      assert_in_delta c1, 10.0, 0.01
      # The first reading had nothing to compare against, so one value so far.
      assert [cpu] = gpu_server.cpu_history
      assert_in_delta cpu, 15.0, 0.01
      assert [%{name: "NVIDIA RTX A6000", history: [_ | _]}, _] = gpu_server.gpus
    end

    test "the first reading has no percentage yet rather than a wrong one" do
      Sampler.sample_now()

      assert [%{cpu: nil} | _] = ServerStatus.snapshot()
    end

    test "a server whose exporter does not answer is listed as unreachable" do
      stub_unreachable()
      Sampler.sample_now()

      assert [
               %{number: 1, reachable?: true},
               %{number: 2, reachable?: false},
               %{number: 3, reachable?: false}
             ] =
               ServerStatus.snapshot()
    end

    test "history keeps a bounded number of readings" do
      for _ <- 1..(ServerStatus.history_length() + 5), do: Sampler.sample_now()

      [_, server | _] = ServerStatus.snapshot()
      assert length(server.cpu_history) == ServerStatus.history_length()
    end
  end

  defp scale_cpu_counters(text, n) do
    Regex.replace(~r/^(node_cpu_seconds_total\{[^}]*\}) (\S+)$/m, text, fn _, series, value ->
      {number, ""} = Float.parse(value)
      "#{series} #{number * n}"
    end)
  end
end
