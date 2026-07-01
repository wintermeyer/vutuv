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
  end
end
