defmodule Vutuv.SsrfTest do
  @moduledoc """
  The SSRF target predicates shared by the URL validators and the fetchers.
  `internal_host?/1` is literal-only (safe in a changeset); `resolves_to_internal?/1`
  adds the fetch-time DNS check that defeats rebinding (issues #775 / #777).
  """
  # Not async: resolves_to_internal? reads the global `:ssrf_resolver` env.
  use ExUnit.Case, async: false

  alias Vutuv.Ssrf

  setup do
    prev = Application.get_env(:vutuv, :ssrf_resolver)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:vutuv, :ssrf_resolver, prev),
        else: Application.delete_env(:vutuv, :ssrf_resolver)
    end)

    :ok
  end

  # Resolve every host to the given IP list, for both address families.
  defp stub_resolver(by_host) do
    Application.put_env(:vutuv, :ssrf_resolver, fn host, _family ->
      {:ok, Map.get(by_host, to_string(host), [])}
    end)
  end

  describe "internal_host?/1 (literal, no DNS)" do
    test "rejects localhost, loopback, private, link-local, metadata and unique-local" do
      for host <- ~w(localhost 127.0.0.1 10.0.0.5 192.168.1.1 172.16.0.1 169.254.169.254) do
        assert Ssrf.internal_host?(host), "expected #{host} to be internal"
      end

      assert Ssrf.internal_host?("[::1]")
      assert Ssrf.internal_host?("[fc00::1]")
      assert Ssrf.internal_host?("[fe80::1]")
      assert Ssrf.internal_host?("[::ffff:10.0.0.5]")
    end

    test "accepts public hosts and public IP literals" do
      refute Ssrf.internal_host?("example.org")
      refute Ssrf.internal_host?("93.184.216.34")
      refute Ssrf.internal_host?("[2606:2800:220:1:248:1893:25c8:1946]")
    end

    test "a nil / hostless URL is not a target" do
      refute Ssrf.internal_host?(nil)
    end
  end

  describe "resolves_to_internal?/1 (fetch-time, with DNS)" do
    test "a literal internal host is internal without any lookup" do
      assert Ssrf.resolves_to_internal?("169.254.169.254")
      assert Ssrf.resolves_to_internal?("[::1]")
    end

    test "a public IP literal is not internal and is not looked up" do
      # The resolver would crash if called, proving the literal short-circuit.
      Application.put_env(:vutuv, :ssrf_resolver, fn _h, _f -> raise "must not resolve" end)
      refute Ssrf.resolves_to_internal?("93.184.216.34")
    end

    test "a public hostname that resolves to an internal IP is internal (DNS rebinding)" do
      stub_resolver(%{"rebind.attacker.example" => [{10, 0, 0, 5}]})
      assert Ssrf.resolves_to_internal?("rebind.attacker.example")
    end

    test "a hostname resolving only to public addresses is not internal" do
      stub_resolver(%{"hooks.example.org" => [{93, 184, 216, 34}]})
      refute Ssrf.resolves_to_internal?("hooks.example.org")
    end

    test "one internal address among public ones still blocks" do
      stub_resolver(%{"mixed.example" => [{93, 184, 216, 34}, {0, 0, 0, 0, 0, 0, 0, 1}]})
      assert Ssrf.resolves_to_internal?("mixed.example")
    end

    test "a host that does not resolve is not internal (the fetch fails on its own)" do
      stub_resolver(%{})
      refute Ssrf.resolves_to_internal?("nxdomain.example")
    end

    test "a nil / hostless URL is treated as a target (fail closed)" do
      assert Ssrf.resolves_to_internal?(nil)
    end
  end
end
