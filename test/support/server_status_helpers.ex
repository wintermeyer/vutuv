defmodule Vutuv.ServerStatusHelpers do
  @moduledoc """
  A fixture installation of three servers for the `/system/status` tests: this
  machine read from a fake `/proc` under `test/support/fixtures/server_status`,
  one exporter host with two graphics cards, and one without.

  The exporter stub lives in the application env (`:server_status_req_options`),
  so every module that uses it is `async: false`; nothing else reads that key.
  """

  import ExUnit.Callbacks

  alias Vutuv.ServerStatus.Sampler

  @fixtures Path.expand("fixtures/server_status", __DIR__)

  def fixture(name), do: File.read!(Path.join(@fixtures, name))

  def root, do: Path.join(@fixtures, "root")

  def sources do
    df = fixture("df.txt")

    [
      %{number: 1, kind: :local, root: root(), df: fn -> df end, gpu_url: nil},
      %{
        number: 2,
        kind: :remote,
        node_url: "http://10.0.0.2:9100/metrics",
        gpu_url: "http://10.0.0.2:9835/metrics"
      },
      %{number: 3, kind: :remote, node_url: "http://10.0.0.3:9100/metrics", gpu_url: nil}
    ]
  end

  @doc """
  Answers every exporter request: the GPU page on 9835, the node page
  elsewhere, passed through `node_page` first so a test can move the counters.
  """
  def stub_exporters(node_page \\ &Function.identity/1) do
    node = fixture("node_exporter.prom")
    gpu = fixture("gpu_exporter.prom")

    stub(fn conn ->
      body = if conn.port == 9835, do: gpu, else: node_page.(node)

      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  @doc "Every exporter refuses the connection."
  def stub_unreachable, do: stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

  def start_sampler!, do: start_supervised!({Sampler, sources: sources(), interval: :manual})

  defp stub(plug) do
    Application.put_env(:vutuv, :server_status_req_options, plug: plug)
    on_exit(fn -> Application.delete_env(:vutuv, :server_status_req_options) end)
  end
end
