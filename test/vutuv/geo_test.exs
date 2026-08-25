defmodule Vutuv.GeoTest do
  use ExUnit.Case, async: true

  alias Vutuv.Geo

  describe "private_or_loopback?/1" do
    test "flags loopback and private-range addresses (tuple or string)" do
      for ip <- [
            {127, 0, 0, 1},
            "127.0.0.1",
            "::1",
            "0.0.0.0",
            "10.1.2.3",
            "192.168.0.5",
            {172, 20, 0, 1},
            "169.254.1.1"
          ] do
        assert Geo.private_or_loopback?(ip), "expected #{inspect(ip)} to be private/loopback"
      end
    end

    test "does not flag public client addresses" do
      for ip <- [{203, 0, 113, 7}, "203.0.113.7", "8.8.8.8", {1, 1, 1, 1}] do
        refute Geo.private_or_loopback?(ip), "expected #{inspect(ip)} to be public"
      end
    end

    test "nil is not private/loopback" do
      refute Geo.private_or_loopback?(nil)
    end

    # On a dual-stack listener a loopback proxy hop arrives IPv4-mapped, which
    # `:inet.ntoa/1` renders "::ffff:127.0.0.1" — matching none of the string
    # prefixes this predicate used to test. The admin dashboard then reported
    # the reverse proxy *was* forwarding the real client address when it was
    # not, which is the one thing this predicate exists to warn about
    # (issues #799, #837). `Ssrf.internal_ip?/1` has always handled the mapped
    # form; it just was not the one being asked.
    test "an IPv4-mapped IPv6 loopback or private address still counts" do
      for ip <- [
            {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1},
            "::ffff:127.0.0.1",
            {0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 5},
            "::ffff:192.168.0.5"
          ] do
        assert Geo.private_or_loopback?(ip), "expected #{inspect(ip)} to be private/loopback"
      end
    end

    # The whole point of delegating: one answer to "is this address internal",
    # and it is the tested one.
    test "it agrees with Vutuv.Ssrf, the owner of that question" do
      for ip <- [
            {127, 0, 0, 1},
            {10, 1, 2, 3},
            {172, 20, 0, 1},
            {203, 0, 113, 7},
            {1, 1, 1, 1},
            {0, 0, 0, 0, 0, 0, 0, 1},
            {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}
          ] do
        assert Geo.private_or_loopback?(ip) == Vutuv.Ssrf.internal_ip?(ip),
               "the two predicates disagree about #{inspect(ip)}"
      end
    end

    test "an unparseable string is not private/loopback" do
      refute Geo.private_or_loopback?("not-an-address")
      refute Geo.private_or_loopback?("")
    end
  end
end
