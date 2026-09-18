defmodule VutuvWeb.UserHTMLTest do
  @moduledoc """
  Pure helpers of `VutuvWeb.UserHTML` that need no database.
  """
  use ExUnit.Case, async: true

  describe "compact_activity_date/2 (Code card last-active date)" do
    test "shows only the year for a date in an earlier year" do
      assert VutuvWeb.UserHTML.compact_activity_date(~D[2025-05-28], ~D[2026-07-09]) == "2025"
    end

    # The shape follows the reader's date region, not the interface language
    # (issue #1502): a German-speaking member in Chicago writes 5/28.
    test "drops the year for a date in the current year, in the reader's region" do
      Vutuv.ViewerClock.put("US", "Etc/UTC", true)
      assert VutuvWeb.UserHTML.compact_activity_date(~D[2026-05-28], ~D[2026-07-09]) == "5/28"

      Vutuv.ViewerClock.put("DE", "Etc/UTC", true)
      assert VutuvWeb.UserHTML.compact_activity_date(~D[2026-05-28], ~D[2026-07-09]) == "28.05."
    end

    test "an earlier year shows only the year, whatever the region" do
      Vutuv.ViewerClock.put("US", "Etc/UTC", true)
      assert VutuvWeb.UserHTML.compact_activity_date(~D[2025-12-31], ~D[2026-01-05]) == "2025"
    end
  end
end
