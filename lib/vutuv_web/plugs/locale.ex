defmodule VutuvWeb.Plug.Locale do
  @moduledoc """
  Resolves everything about a request that is "where the reader is": the
  interface language, the date shape they read (`Vutuv.DateRegions`) and the
  time zone their stamps are written in (`Vutuv.ViewerClock`).

  The language goes into Gettext, the other two into the viewer clock, and both
  are also stored in the session so a LiveView — a process this plug never ran
  in — can pick them up on mount (`VutuvWeb.LiveLocale`).
  """

  import Plug.Conn

  alias Vutuv.Accounts.User
  alias Vutuv.DateRegions
  alias Vutuv.Languages
  alias Vutuv.ViewerClock

  def init(default), do: default

  def call(conn, _default) do
    conn
    |> handle_locale(conn.assigns[:current_user])
    |> put_viewer_clock(conn.assigns[:current_user])
  end

  defp handle_locale(conn, %User{locale: nil}), do: handle_locale(conn, nil)

  defp handle_locale(conn, nil) do
    # Get locales from header
    Plug.Conn.get_req_header(conn, "accept-language")
    # Split header to a list of supported locales
    |> process_header
    # Cross reference list with supported locales and return supported locale, otherwise return most preferred locale
    |> get_supported_locale
    # Assign locale to conn assigns, and pass to gettext. Return conn struct.
    |> assign_locale(conn)
  end

  defp handle_locale(conn, %User{locale: loc}) do
    assign_locale(loc, conn)
  end

  # The date shape and time zone this reader gets. The browser's own guess is
  # kept beside the resolved value — the sign-up form stamps it on the new
  # account (`Vutuv.Accounts`), and a LiveView mount re-runs the same
  # resolution off the session, so it has to travel there too.
  defp put_viewer_clock(conn, user) do
    browser_region = DateRegions.from_accept_language(get_req_header(conn, "accept-language"))
    ViewerClock.put_viewer(user, browser_region)

    conn
    |> assign(:browser_date_region, browser_region)
    |> store_in_session(:date_region, browser_region)
  end

  defp process_header([]), do: []

  # Splits header on commas.
  defp process_header(header) do
    header
    |> hd
    |> String.split(",")
  end

  defp get_supported_locale([]), do: nil

  # Returns the first header locale whose base subtag the app supports,
  # else the visitor's most preferred locale.
  defp get_supported_locale(locales) do
    Enum.find_value(locales, get_first_locale(locales), fn entry ->
      base =
        entry
        |> String.split(";")
        |> hd()
        |> String.split("-")
        |> hd()

      if locale_supported?(base), do: base
    end)
  end

  # Give locale data to all modules that require it. The locale also goes into
  # the session so LiveViews — which run in their own process, where this plug
  # never ran — can pick it up on mount (see `VutuvWeb.Live.InitAssigns` and
  # `VutuvWeb.ShellLive`). Without that, /messages and /notifications flipped
  # the whole chrome back to English for German users.
  #
  # An unsupported result (nil, or a browser subtag like "fr" that no config
  # locale matches) falls back to "en" rather than being put into Gettext, the
  # `<html lang>` and the session as a dead value that renders English content
  # under a foreign lang tag.
  defp assign_locale(locale, conn) do
    locale = if locale_supported?(locale), do: locale, else: "en"
    Gettext.put_locale(VutuvWeb.Gettext, locale)

    conn
    |> assign(:locale, locale)
    |> store_in_session(:locale, locale)
  end

  # API requests run this plug without a fetched session — skip them.
  defp store_in_session(conn, key, value) do
    case conn.private do
      %{plug_session_fetch: :done} -> put_session(conn, key, value)
      _ -> conn
    end
  end

  # Gets the first locale provided
  defp get_first_locale(locales) do
    locales
    |> hd
    |> String.split("-")
    |> hd
  end

  def locale_supported?(nil), do: false

  # Checks locale provided against app config for supported locales. Must be
  # exact equality, not a substring match: callers (address_controller, the
  # emailer) pass arbitrary strings, and a 3-letter subtag that is a superstring
  # of a supported 2-letter code ("deu" contains "de", "eng" contains "en")
  # would false-match under `String.contains?/2`.
  def locale_supported?(locale), do: locale in Languages.site_locales()
end
