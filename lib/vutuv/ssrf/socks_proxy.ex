defmodule Vutuv.Ssrf.SocksProxy do
  @moduledoc """
  A loopback SOCKS5 proxy that vets **every single connection** the
  headless-capture Chromium makes against `Vutuv.Ssrf` — the SSRF egress
  control for member-supplied screenshot URLs (GHSA-mmjf-8cwc-6vwv, CWE-918).

  ## Why a proxy at all — the history

  The captured URL is member-supplied, so headless Chromium is an SSRF risk:
  left to itself it resolves DNS and follows redirects, `<meta refresh>` and
  JavaScript navigations, and could be steered onto `169.254.169.254`,
  `127.0.0.1:<port>` or any LAN host and publish the rendered result on the
  attacker's own link card. Vetting only the seed URL does not help — the
  *browser* is what fetches.

  The first egress control (v7.141.2) pinned Chromium to the seed host's
  pre-vetted IP with `--host-resolver-rules=MAP * <ip>`. That closed the DNS
  side completely, but with a fidelity cost that turned out to be much bigger
  than "some third-party widget won't load": `MAP *` sends every **subresource
  host** to the seed's IP too, and most large sites serve their CSS/JS from a
  separate CDN domain. GitHub loads all styling from `github.githubassets.com`;
  pinned to `github.com`'s address, that TLS handshake dies on a certificate
  mismatch (`ERR_CERT_COMMON_NAME_INVALID`) and every GitHub link card
  screenshotted as bare unstyled 1995-looking HTML. Any site with an asset
  CDN degraded the same way.

  So the pin was replaced by this proxy: Chromium egresses through it, and the
  vetting moves from "one IP for the whole run" to "each connection's target is
  resolved and vetted the moment it is dialled". Cross-host assets now load
  from their real (vetted) addresses, so the shot looks like the page — while
  internal targets stay unreachable, connection by connection.

  ## Why SOCKS5 specifically

  Chromium treats a `socks5://` proxy as **remote-DNS** (see its network-stack
  docs): it does not resolve hostnames itself but sends each one to the proxy
  inside the CONNECT request. That is exactly the property the vetting needs —
  the proxy sees the *name*, resolves it once via `Vutuv.Ssrf.vetted_address/1`
  (fail closed: any internal answer refuses), and then dials the exact IP it
  just vetted. There is no second lookup anywhere, so the check-vs-fetch
  (TOCTOU) rebinding window the old pin closed stays closed. SOCKS5 is also
  the smallest protocol with that property: an HTTP forward proxy would need
  header parsing and CONNECT special-casing for the same result; TLS is passed
  through untouched either way (no MITM).

  A CONNECT that names an IP **literal** (ATYP 1/4) is vetted against
  `Vutuv.Ssrf.internal_ip?/1` directly — which the resolver-rule approach
  could not reliably cover, since a literal never consults the resolver. So
  `<img src="http://127.0.0.1:9100/...">` is refused here, by the same guard.

  Chromium is launched with `--host-resolver-rules=MAP * ~NOTFOUND,EXCLUDE
  127.0.0.1` alongside (Chromium's own documented SOCKS recipe): any name
  resolution attempted *outside* the proxy fails, so a code path that bypassed
  the proxy could still not reach the network by name. Both halves fail
  closed, and so does the caller: `Vutuv.PageScreenshot` refuses to launch
  Chromium at all when this proxy is not running (`{:error, :not_running}`
  from `port/1`), rather than degrade to an unvetted capture.

  ## Scope and non-goals

    * Listens on `127.0.0.1` only, on an ephemeral port (read it via
      `port/1`) — never reachable from outside the host. A local process
      could relay *outbound* through it, which grants nothing it does not
      already have; internal targets are refused for it too.
    * Only `CONNECT` (TCP) is implemented. Chromium needs nothing else here:
      no remote DNS over UDP (hostnames ride in CONNECT), and QUIC/HTTP3 is
      not attempted through a SOCKS proxy — sites fall back to TCP.
    * No authentication (method `0x00`): the trust boundary is the loopback
      bind, and the vetting applies to every client equally.
    * `Vutuv.Moderation.EvidenceScreenshot` deliberately does **not** use the
      proxy — it shoots this installation's *own* host, which may
      legitimately resolve internally (dev, intranet installs).

  One instance runs in the application supervision tree. The `:vet` option
  (a `fun({:domain, host} | {:ip, ip_tuple}) -> {:ok, ip} | {:error, term}`)
  exists for tests only; the default is `default_vet/1` on `Vutuv.Ssrf`.
  """

  use GenServer

  require Logger

  alias Vutuv.Ssrf

  @handshake_timeout 10_000
  @connect_timeout 10_000
  # A capture's Chromium is force-killed ~30s after launch
  # (Vutuv.PageScreenshot.capture_seconds/0), closing its proxy connections;
  # a relay idle this long has lost its client, so close it rather than leak
  # the handler process.
  @idle_timeout 120_000

  # SOCKS5 reply codes (RFC 1928 §6).
  @rep_success 0x00
  @rep_general_failure 0x01
  @rep_not_allowed 0x02
  @rep_network_unreachable 0x03
  @rep_host_unreachable 0x04
  @rep_refused 0x05
  @rep_cmd_not_supported 0x07
  @rep_atyp_not_supported 0x08

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  The loopback TCP port the proxy listens on, as `{:ok, port}` — or
  `{:error, :not_running}` when the proxy is down, which the capture path
  must treat as "do not launch Chromium" (fail closed), never as "capture
  without protection".
  """
  def port(server \\ __MODULE__) do
    {:ok, GenServer.call(server, :port)}
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc """
  The production vetting: a hostname goes through `Vutuv.Ssrf.vetted_address/1`
  (resolve once, refuse if any answer is internal, dial exactly the vetted IP);
  an IP literal is checked against `Vutuv.Ssrf.internal_ip?/1` directly.
  """
  def default_vet({:domain, host}), do: Ssrf.vetted_address(host)

  def default_vet({:ip, ip}) do
    if Ssrf.internal_ip?(ip), do: {:error, :internal}, else: {:ok, ip}
  end

  @impl true
  def init(opts) do
    vet = Keyword.get(opts, :vet, &default_vet/1)

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        ip: {127, 0, 0, 1},
        active: false,
        reuseaddr: true,
        backlog: 64
      ])

    {:ok, port} = :inet.port(listen)
    {:ok, _acceptor} = Task.start_link(fn -> accept_loop(listen, vet) end)
    {:ok, %{listen: listen, port: port}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  # Each accepted connection is served by its own supervised task, so a
  # malformed or hostile client can only ever break its own handler. The
  # `:go` message gates the handler until socket ownership has transferred
  # (passive-mode recv is owner-only).
  defp accept_loop(listen, vet) do
    case :gen_tcp.accept(listen) do
      {:ok, client} ->
        {:ok, pid} =
          Task.Supervisor.start_child(Vutuv.TaskSupervisor, fn ->
            receive do
              {:go, socket} -> serve(socket, vet)
            after
              5_000 -> :ok
            end
          end)

        :ok = :gen_tcp.controlling_process(client, pid)
        send(pid, {:go, client})
        accept_loop(listen, vet)

      # The listen socket died with the GenServer (shutdown/restart): stop.
      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.error("socks proxy accept failed: #{inspect(reason)}")
        accept_loop(listen, vet)
    end
  end

  defp serve(client, vet) do
    with {:ok, methods} <- recv_greeting(client),
         :ok <- select_no_auth(client, methods),
         {:ok, target, port} <- read_request(client) do
      connect_vetted(client, vet, target, port)
    else
      {:refuse, rep} -> reply(client, rep)
      _error -> :ok
    end

    :gen_tcp.close(client)
  end

  defp recv_greeting(client) do
    with {:ok, <<5, n>>} <- :gen_tcp.recv(client, 2, @handshake_timeout),
         true <- n > 0,
         {:ok, methods} <- :gen_tcp.recv(client, n, @handshake_timeout) do
      {:ok, methods}
    else
      _malformed -> :error
    end
  end

  defp select_no_auth(client, methods) do
    if :binary.match(methods, <<0>>) == :nomatch do
      :gen_tcp.send(client, <<5, 0xFF>>)
      :error
    else
      :gen_tcp.send(client, <<5, 0>>)
    end
  end

  defp read_request(client) do
    case :gen_tcp.recv(client, 4, @handshake_timeout) do
      {:ok, <<5, 1, _rsv, atyp>>} -> read_target(client, atyp)
      {:ok, <<5, _cmd, _rsv, _atyp>>} -> {:refuse, @rep_cmd_not_supported}
      _error -> :error
    end
  end

  defp read_target(client, atyp) do
    with {:ok, target} <- read_address(client, atyp),
         {:ok, <<port::16>>} <- :gen_tcp.recv(client, 2, @handshake_timeout) do
      {:ok, target, port}
    else
      {:refuse, rep} -> {:refuse, rep}
      _error -> :error
    end
  end

  defp read_address(client, 1) do
    with {:ok, <<a, b, c, d>>} <- :gen_tcp.recv(client, 4, @handshake_timeout) do
      {:ok, {:ip, {a, b, c, d}}}
    end
  end

  defp read_address(client, 3) do
    with {:ok, <<len>>} <- :gen_tcp.recv(client, 1, @handshake_timeout),
         true <- len > 0,
         {:ok, host} <- :gen_tcp.recv(client, len, @handshake_timeout) do
      {:ok, {:domain, host}}
    else
      _malformed -> :error
    end
  end

  defp read_address(client, 4) do
    with {:ok, <<w1::16, w2::16, w3::16, w4::16, w5::16, w6::16, w7::16, w8::16>>} <-
           :gen_tcp.recv(client, 16, @handshake_timeout) do
      {:ok, {:ip, {w1, w2, w3, w4, w5, w6, w7, w8}}}
    end
  end

  defp read_address(_client, _atyp), do: {:refuse, @rep_atyp_not_supported}

  # The heart of the guard: resolve-and-vet at dial time, connect to exactly
  # the vetted address (never to what the client asked for by name, and never
  # via a second lookup).
  defp connect_vetted(client, vet, target, port) do
    case vet.(target) do
      {:ok, ip} -> connect_upstream(client, ip, port)
      {:error, _refused} -> reply(client, @rep_not_allowed)
    end
  end

  defp connect_upstream(client, ip, port) do
    case :gen_tcp.connect(ip, port, [:binary, active: false], @connect_timeout) do
      {:ok, upstream} ->
        reply(client, @rep_success)
        :ok = :inet.setopts(client, active: :once)
        :ok = :inet.setopts(upstream, active: :once)
        relay(client, upstream)
        :gen_tcp.close(upstream)

      {:error, reason} ->
        reply(client, connect_rep(reason))
    end
  end

  defp connect_rep(:econnrefused), do: @rep_refused
  defp connect_rep(:timeout), do: @rep_host_unreachable
  defp connect_rep(:ehostunreach), do: @rep_host_unreachable
  defp connect_rep(:enetunreach), do: @rep_network_unreachable
  defp connect_rep(_other), do: @rep_general_failure

  # BND.ADDR/BND.PORT carry no information for a CONNECT client; Chromium
  # ignores them, so answer the conventional 0.0.0.0:0.
  defp reply(client, rep) do
    :gen_tcp.send(client, <<5, rep, 0, 1, 0, 0, 0, 0, 0, 0>>)
    :ok
  end

  # Byte pump between client and upstream. `active: :once` per direction gives
  # backpressure: the next chunk is only asked for after the previous one was
  # written through.
  defp relay(a, b) do
    receive do
      {:tcp, socket, data} ->
        other = if socket == a, do: b, else: a

        with :ok <- :gen_tcp.send(other, data),
             :ok <- :inet.setopts(socket, active: :once) do
          relay(a, b)
        end

      {:tcp_closed, _socket} ->
        :ok

      {:tcp_error, _socket, _reason} ->
        :ok
    after
      @idle_timeout -> :ok
    end
  end
end
