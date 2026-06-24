defmodule Vutuv.BuildInfoTest do
  use ExUnit.Case, async: true

  alias Vutuv.BuildInfo

  describe "built_at/0" do
    test "returns a UTC DateTime stamped at compile time" do
      assert %DateTime{time_zone: "Etc/UTC"} = BuildInfo.built_at()
    end
  end

  describe "deployed_date/1 and deployed_time/1" do
    test "format a UTC instant as Berlin wall clock, DD.MM.YYYY and HH:MM" do
      # Summer (CEST, UTC+2): 12:30 UTC -> 14:30 Berlin on 24.06.2026.
      assert BuildInfo.deployed_date(~U[2026-06-24 12:30:00Z]) == "24.06.2026"
      assert BuildInfo.deployed_time(~U[2026-06-24 12:30:00Z]) == "14:30"
      # Winter (CET, UTC+1): 12:00 UTC -> 13:00 Berlin on 15.01.2026.
      assert BuildInfo.deployed_date(~U[2026-01-15 12:00:00Z]) == "15.01.2026"
      assert BuildInfo.deployed_time(~U[2026-01-15 12:00:00Z]) == "13:00"
    end

    test "default to the build timestamp" do
      assert BuildInfo.deployed_date() =~ ~r/^\d{2}\.\d{2}\.\d{4}$/
      assert BuildInfo.deployed_time() =~ ~r/^\d{2}:\d{2}$/
    end
  end
end
