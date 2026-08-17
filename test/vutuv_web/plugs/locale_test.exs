defmodule VutuvWeb.Plug.LocaleTest do
  @moduledoc """
  `locale_supported?/1` gates which locales the app accepts (the request-locale
  plug, the address-controller template pick and the emailer language). It must
  test **exact** membership against the configured locales (`~w(en de)`), never a
  substring: a 3-letter subtag that is a superstring of a supported 2-letter code
  ("deu" contains "de", "eng" contains "en") used to false-match under the old
  `String.contains?/2` check.
  """
  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 2]
  import Plug.Conn, only: [put_req_header: 3, assign: 3]

  alias Vutuv.Accounts.User
  alias Vutuv.Prefs
  alias Vutuv.ViewerClock
  alias VutuvWeb.Plug.Locale

  @session Plug.Session.init(store: :cookie, key: "_test", signing_salt: "locale-test")

  defp call(accept_language, user \\ nil) do
    conn(:get, "/")
    |> put_req_header("accept-language", accept_language)
    |> Plug.Session.call(@session)
    |> Plug.Conn.fetch_session()
    |> assign(:current_user, user)
    |> Locale.call([])
  end

  # The plug is also where the reader's clock is resolved (issue #1502): it is
  # the one place that has both the member record and the request headers.
  describe "call/2 — the viewer clock" do
    test "guesses the date region from Accept-Language for a visitor" do
      call("en-US,en;q=0.9")
      assert ViewerClock.region() == "US"

      call("de-DE,de;q=0.9")
      assert ViewerClock.region() == "DE"
    end

    test "a member's own region beats the browser's" do
      call("en-US,en;q=0.9", %User{locale: "en", date_region: "ISO"})

      assert ViewerClock.region() == "ISO"
    end

    test "a header naming no shape we know falls back to the installation default" do
      call("xx-YY")

      assert ViewerClock.region() == Prefs.default(:date_region)
    end

    test "a member's own zone is used and marked as theirs" do
      call("de-DE", %User{locale: "de", time_zone: "America/Denver"})

      assert ViewerClock.zone() == "America/Denver"
      assert ViewerClock.own_zone?()
    end

    test "without an own zone the installation default stands and the browser keeps the last word" do
      call("de-DE")

      assert ViewerClock.zone() == Prefs.default(:time_zone)
      refute ViewerClock.own_zone?()
    end

    # A LiveView mount has no request headers, so the guess has to travel in the
    # session the way the locale already does.
    test "the browser guess is assigned and stored in the session for LiveView mounts" do
      conn = call("en-GB,en;q=0.9")

      assert conn.assigns.browser_date_region == "GB"
      assert Plug.Conn.get_session(conn, "date_region") == "GB"
    end
  end

  describe "locale_supported?/1" do
    test "the exact configured codes are supported" do
      assert Locale.locale_supported?("de")
      assert Locale.locale_supported?("en")
    end

    test "a 3-letter superstring of a supported code is NOT supported" do
      refute Locale.locale_supported?("deu")
      refute Locale.locale_supported?("eng")
    end

    test "nil and unrelated codes are not supported" do
      refute Locale.locale_supported?(nil)
      refute Locale.locale_supported?("fr")
      refute Locale.locale_supported?("generic")
    end
  end
end
