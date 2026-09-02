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

    # The filter is a deny list, so every range it does not name is reachable.
    # These eight were missing: an address that is not RFC 1918 can still be
    # somebody's internal network (carrier-grade NAT), a lab, a local stand-in
    # (the documentation ranges), or not a unicast host at all.
    test "rejects the reserved ranges that are not RFC 1918" do
      for host <- ~w(100.64.0.1 100.127.255.254 192.0.0.8 192.0.2.1 198.18.0.1
                     198.51.100.1 203.0.113.1 224.0.0.1 239.255.255.250
                     240.0.0.1 255.255.255.255) do
        assert Ssrf.internal_host?(host), "expected #{host} to be internal"
      end

      assert Ssrf.internal_host?("[fec0::1]")
      assert Ssrf.internal_host?("[2001:db8::1]")
      # IPv4-compatible IPv6, the deprecated ::a.b.c.d form.
      assert Ssrf.internal_host?("[::127.0.0.1]")
      assert Ssrf.internal_host?("[::169.254.169.254]")
    end

    # The neighbours of each new range, so a guard's bounds are pinned rather
    # than just its middle.
    test "leaves the public addresses next to those ranges alone" do
      for host <- ~w(100.63.255.255 100.128.0.1 192.0.1.1 192.0.3.1 198.17.255.255
                     198.20.0.1 198.51.99.1 203.0.112.1 223.255.255.255) do
        refute Ssrf.internal_host?(host), "expected #{host} to be public"
      end
    end

    test "accepts public hosts and public IP literals" do
      refute Ssrf.internal_host?("example.org")
      refute Ssrf.internal_host?("93.184.216.34")
      refute Ssrf.internal_host?("[2606:2800:220:1:248:1893:25c8:1946]")
    end

    # The two predicates answer different questions and must not be merged.
    # `internal_ip?/1` is also `Vutuv.Geo.private_or_loopback?/1` (is this
    # visitor's own address private?) and the filter `Vutuv.Dns` drops
    # nameservers with. Folding the reserved ranges into it made 203.0.113.7
    # read as a private client and 2001:db8::1 as an unusable nameserver.
    test "reserved is not the same question as private" do
      for ip <- [
            {203, 0, 113, 7},
            {100, 64, 0, 1},
            {224, 0, 0, 1},
            {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}
          ] do
        refute Ssrf.internal_ip?(ip), "#{inspect(ip)} is reserved, not private"
        assert Ssrf.unroutable_ip?(ip), "#{inspect(ip)} must still be refused an outbound fetch"
      end

      # Private addresses are both, and the loopback written the long way round
      # is genuinely loopback rather than merely reserved.
      for ip <- [{127, 0, 0, 1}, {10, 0, 0, 5}, {0, 0, 0, 0, 0, 0, 0x7F00, 1}] do
        assert Ssrf.internal_ip?(ip)
        assert Ssrf.unroutable_ip?(ip)
      end
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

  describe "vetted_address/1 (resolve once, return a pinnable public IP)" do
    test "a public IP literal returns itself without any lookup" do
      Application.put_env(:vutuv, :ssrf_resolver, fn _h, _f -> raise "must not resolve" end)
      assert Ssrf.vetted_address("93.184.216.34") == {:ok, {93, 184, 216, 34}}
    end

    test "a literal internal host is refused without any lookup" do
      Application.put_env(:vutuv, :ssrf_resolver, fn _h, _f -> raise "must not resolve" end)
      assert Ssrf.vetted_address("169.254.169.254") == {:error, :internal}
      assert Ssrf.vetted_address("localhost") == {:error, :internal}
    end

    test "an all-public hostname returns its first resolved address (to pin on)" do
      stub_resolver(%{"public.example" => [{93, 184, 216, 34}]})
      assert Ssrf.vetted_address("public.example") == {:ok, {93, 184, 216, 34}}
    end

    test "one internal address among public ones fails closed" do
      stub_resolver(%{"rebind.example" => [{93, 184, 216, 34}, {10, 0, 0, 5}]})
      assert Ssrf.vetted_address("rebind.example") == {:error, :internal}
    end

    test "a host that resolves to nothing is unresolvable (never handed to a fetcher)" do
      stub_resolver(%{})
      assert Ssrf.vetted_address("nxdomain.example") == {:error, :unresolvable}
    end

    test "a nil / hostless value is unresolvable" do
      assert Ssrf.vetted_address(nil) == {:error, :unresolvable}
    end
  end
end
