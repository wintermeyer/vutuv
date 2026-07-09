defmodule VutuvWeb.UserHTMLTest do
  @moduledoc """
  Covers the "Member since" label rendered in the profile header: just the
  year for older accounts, the spelled-out month for accounts created in the
  current year (where a bare year would read oddly for a fresh profile).
  """
  use ExUnit.Case, async: true

  alias Vutuv.Accounts.User

  describe "member_since/1" do
    test "shows just the year for accounts created in a past year" do
      user = %User{inserted_at: ~N[2008-02-15 10:00:00]}
      assert VutuvWeb.UserHTML.member_since(user) == "Member since 2008"
    end

    test "spells out the month for accounts created in the current year" do
      today = Date.utc_today()
      user = %User{inserted_at: NaiveDateTime.new!(today.year, today.month, 1, 12, 0, 0)}
      month = Calendar.strftime(today, "%B")

      assert VutuvWeb.UserHTML.member_since(user) == "Member since #{month} #{today.year}"
    end

    test "returns nil when the account has no inserted_at yet" do
      assert VutuvWeb.UserHTML.member_since(%User{}) == nil
    end

    test "follows the viewer's locale (German)" do
      Gettext.put_locale(VutuvWeb.Gettext, "de")

      assert VutuvWeb.UserHTML.member_since(%User{inserted_at: ~N[2008-02-15 10:00:00]}) ==
               "Mitglied seit 2008"

      today = Date.utc_today()
      user = %User{inserted_at: NaiveDateTime.new!(today.year, today.month, 1, 12, 0, 0)}

      de_month =
        Enum.at(
          ~w(Januar Februar März April Mai Juni Juli August September Oktober November Dezember),
          today.month - 1
        )

      assert VutuvWeb.UserHTML.member_since(user) == "Mitglied seit #{de_month} #{today.year}"
    end
  end

  describe "compact_activity_date/2 (Code card last-active date)" do
    test "shows only the year for a date in an earlier year" do
      assert VutuvWeb.UserHTML.compact_activity_date(~D[2025-05-28], ~D[2026-07-09]) == "2025"
    end

    test "drops the year for a date in the current year (English day/month)" do
      assert VutuvWeb.UserHTML.compact_activity_date(~D[2026-05-28], ~D[2026-07-09]) == "5/28"
    end

    test "German current year shows day.month. with a trailing dot" do
      Gettext.put_locale(VutuvWeb.Gettext, "de")
      assert VutuvWeb.UserHTML.compact_activity_date(~D[2026-05-28], ~D[2026-07-09]) == "28.05."
    end

    test "German earlier year shows only the year" do
      Gettext.put_locale(VutuvWeb.Gettext, "de")
      assert VutuvWeb.UserHTML.compact_activity_date(~D[2025-12-31], ~D[2026-01-05]) == "2025"
    end
  end
end
