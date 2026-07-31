defmodule Vutuv.Ssrf.SocksProxyTest do
  @moduledoc """
  The loopback SOCKS5 proxy that headless Chromium captures egress through.
  Chromium hands it the *hostname* of every connection (the seed page, each
  subresource host, any redirect target), so each one is resolved and vetted
  server-side (`Vutuv.Ssrf`) right before connecting — internal targets are
  refused with REP 0x02 and never dialled. See `Vutuv.Ssrf.SocksProxy` for why
  this replaced the `--host-resolver-rules=MAP * <ip>` pin.

  Not async: one test drives the default vet through the global `:ssrf_resolver`
  app env (the same env `Vutuv.PageScreenshotTest` mutates).
  """
  use ExUnit.Case, async: false

  alias Vutuv.Ssrf.SocksProxy

  setup do
    prev_resolver = Application.get_env(:vutuv, :ssrf_resolver)
    on_exit(fn -> Application.put_env(:vutuv, :ssrf_resolver, prev_resolver) end)
    :ok
  end

  test "relays bytes both ways, connecting by hostname to the IP the vet returned" do
    # The vet sees the hostname (that is the whole point of SOCKS5 over a DNS
    # pin: per-connection vetting needs the name) and answers with the address
    # the proxy must dial — here a local echo server standing in for the
    # vetted public IP.
    test_pid = self()

    vet = fn target ->
      send(test_pid, {:vetted, target})
      {:ok, {127, 0, 0, 1}}
    end

    proxy_port = start_proxy(vet: vet)
    echo_port = start_echo_server()

    sock = open_client(proxy_port)
    handshake(sock)
    assert connect_request(sock, {:domain, "assets.example"}, echo_port) == 0
    assert_received {:vetted, {:domain, "assets.example"}}

    :ok = :gen_tcp.send(sock, "ping")
    assert {:ok, "ping"} = :gen_tcp.recv(sock, 4, 5_000)
    :ok = :gen_tcp.send(sock, "pong")
    assert {:ok, "pong"} = :gen_tcp.recv(sock, 4, 5_000)
  end

  test "a vet refusal answers REP 2 (not allowed by ruleset) and closes without dialling" do
    proxy_port = start_proxy(vet: fn _target -> {:error, :internal} end)

    sock = open_client(proxy_port)
    handshake(sock)
    assert connect_request(sock, {:domain, "rebind.example"}, 443) == 2
    assert {:error, :closed} = :gen_tcp.recv(sock, 1, 5_000)
  end

  test "the default vet refuses localhost and internal IP literals without any DNS" do
    # IP-literal subresources (<img src="http://127.0.0.1/...">) never hit a
    # resolver, so the old `MAP *` rule could not reliably catch them — the
    # proxy vets the literal itself.
    proxy_port = start_proxy()

    for target <- [
          {:domain, "localhost"},
          {:ipv4, {127, 0, 0, 1}},
          {:ipv4, {10, 0, 0, 5}},
          {:ipv4, {169, 254, 169, 254}},
          {:ipv6, {0, 0, 0, 0, 0, 0, 0, 1}}
        ] do
      sock = open_client(proxy_port)
      handshake(sock)
      assert connect_request(sock, target, 80) == 2, "expected refusal for #{inspect(target)}"
    end
  end

  test "the default vet refuses a hostname that resolves to an internal address (rebinding)" do
    Application.put_env(:vutuv, :ssrf_resolver, fn _host, _family -> {:ok, [{10, 0, 0, 5}]} end)
    proxy_port = start_proxy()

    sock = open_client(proxy_port)
    handshake(sock)
    assert connect_request(sock, {:domain, "public-looking.example"}, 443) == 2
  end

  test "an unreachable vetted target answers REP 5 (connection refused), not a hang" do
    # Grab an ephemeral port nothing listens on by opening and closing a listener.
    {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, dead_port} = :inet.port(listen)
    :ok = :gen_tcp.close(listen)

    proxy_port = start_proxy(vet: fn _target -> {:ok, {127, 0, 0, 1}} end)

    sock = open_client(proxy_port)
    handshake(sock)
    assert connect_request(sock, {:domain, "gone.example"}, dead_port) == 5
  end

  test "a non-CONNECT command is refused with REP 7" do
    proxy_port = start_proxy()

    sock = open_client(proxy_port)
    handshake(sock)
    # CMD 3 = UDP ASSOCIATE; the capture path only ever needs TCP CONNECT.
    :ok = :gen_tcp.send(sock, <<5, 3, 0, 1, 127, 0, 0, 1, 80::16>>)
    assert recv_reply(sock) == 7
  end

  test "a client that cannot do no-auth is turned away" do
    proxy_port = start_proxy()

    sock = open_client(proxy_port)
    # Offers only method 0x02 (username/password); the proxy speaks 0x00 only.
    :ok = :gen_tcp.send(sock, <<5, 1, 2>>)
    assert {:ok, <<5, 0xFF>>} = :gen_tcp.recv(sock, 2, 5_000)
    assert {:error, :closed} = :gen_tcp.recv(sock, 1, 5_000)
  end

  test "port/1 fails closed when the proxy is not running" do
    # The capture path must refuse to launch Chromium unprotected, so a dead
    # proxy has to surface as an error, never as a crash or a silent fallback.
    assert {:error, :not_running} = SocksProxy.port(:socks_proxy_test_no_such_instance)
  end

  test "the application runs one global instance for the capture path" do
    assert {:ok, port} = SocksProxy.port()
    assert is_integer(port)
  end

  # -- SOCKS5 client + fixture helpers ---------------------------------------

  defp start_proxy(opts \\ []) do
    name = :"socks_proxy_test_#{System.unique_integer([:positive])}"
    start_supervised!({SocksProxy, Keyword.put(opts, :name, name)})
    {:ok, port} = SocksProxy.port(name)
    port
  end

  defp open_client(proxy_port) do
    {:ok, sock} = :gen_tcp.connect({127, 0, 0, 1}, proxy_port, [:binary, active: false])
    sock
  end

  defp handshake(sock) do
    :ok = :gen_tcp.send(sock, <<5, 1, 0>>)
    assert {:ok, <<5, 0>>} = :gen_tcp.recv(sock, 2, 5_000)
  end

  defp connect_request(sock, {:domain, host}, port) do
    :ok = :gen_tcp.send(sock, <<5, 1, 0, 3, byte_size(host), host::binary, port::16>>)
    recv_reply(sock)
  end

  defp connect_request(sock, {:ipv4, {a, b, c, d}}, port) do
    :ok = :gen_tcp.send(sock, <<5, 1, 0, 1, a, b, c, d, port::16>>)
    recv_reply(sock)
  end

  defp connect_request(sock, {:ipv6, words}, port) do
    addr = words |> Tuple.to_list() |> Enum.map_join(&<<&1::16>>)
    :ok = :gen_tcp.send(sock, <<5, 1, 0, 4, addr::binary, port::16>>)
    recv_reply(sock)
  end

  defp recv_reply(sock) do
    assert {:ok, <<5, rep, 0, 1, _bnd::binary-size(6)>>} = :gen_tcp.recv(sock, 10, 5_000)
    rep
  end

  defp start_echo_server do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen)
    {:ok, _pid} = Task.start_link(fn -> echo_accept(listen) end)
    port
  end

  defp echo_accept(listen) do
    {:ok, conn} = :gen_tcp.accept(listen, 10_000)
    echo_loop(conn)
  end

  defp echo_loop(conn) do
    case :gen_tcp.recv(conn, 0, 10_000) do
      {:ok, data} ->
        :ok = :gen_tcp.send(conn, data)
        echo_loop(conn)

      _closed ->
        :gen_tcp.close(conn)
    end
  end
end
