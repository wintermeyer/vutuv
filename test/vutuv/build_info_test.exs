defmodule Vutuv.BuildInfoTest do
  use ExUnit.Case, async: true

  alias Vutuv.BuildInfo

  describe "built_at/0" do
    test "returns a UTC DateTime stamped at compile time" do
      assert %DateTime{time_zone: "Etc/UTC"} = BuildInfo.built_at()
    end
  end

  describe "deployed_at/1" do
    test "formats a UTC instant as Berlin wall clock, HH:MM DD.MM.YYYY" do
      # Summer (CEST, UTC+2): 12:30 UTC -> 14:30 Berlin.
      assert BuildInfo.deployed_at(~U[2026-06-24 12:30:00Z]) == "14:30 24.06.2026"
      # Winter (CET, UTC+1): 12:00 UTC -> 13:00 Berlin.
      assert BuildInfo.deployed_at(~U[2026-01-15 12:00:00Z]) == "13:00 15.01.2026"
    end

    test "defaults to the build timestamp" do
      assert BuildInfo.deployed_at() =~ ~r/^\d{2}:\d{2} \d{2}\.\d{2}\.\d{4}$/
    end
  end
end
