defmodule VutuvWeb.Plug.Locale do
  @moduledoc """
  Resolves everything about a request that is "where the reader is": the
  interface language, the date shape they read (`Vutuv.DateRegions`) and the
  time zone their stamps are written in (`Vutuv.ViewerClock`).

  The language goes into Gettext, the other two into the viewer clock, and both
  are also stored in the session so a LiveView — a process this plug never ran
  in — can pick them up on mount (`VutuvWeb.LiveLocale`).

  The fourth thing it resolves is what the reader's *line* is: data-saving
  mode (`Vutuv.LowBandwidth`), the same per-process shape as the clock, plus
  a cookie kept in step with it for the reverse proxy.
  """

  import Plug.Conn

  alias Vutuv.Accounts.User
  alias Vutuv.DateRegions
  alias Vutuv.Languages
  alias Vutuv.LowBandwidth
  alias Vutuv.ViewerClock

  # A year: the cookie mirrors a stored preference and is re-asserted on every
  # browser request anyway, so its lifetime only decides how long a member who
  # stops visiting keeps it.
  @cookie_max_age 365 * 24 * 60 * 60

  def init(default), do: default

  def call(conn, _default) do
    conn
    |> handle_locale(conn.assigns[:current_user])
    |> put_viewer_clock(conn.assigns[:current_user])
    |> put_low_bandwidth(conn.assigns[:current_user])
  end

  # Data-saving mode for this process (`Vutuv.LowBandwidth.on?/0`), and the
  # cookie nginx can route on. The cookie is written only when it disagrees
  # with the preference, so the common request carries no Set-Cookie at all,
  # and only on a browser request — an API call has no cookie jar to keep in
  # step. Same attributes as the session cookie: `Secure` follows the scheme
  # (Plug's default), and there is nothing in it worth reading from a script.
  defp put_low_bandwidth(conn, user) do
    on? = LowBandwidth.put_viewer(user)

    if cookies_fetched?(conn), do: sync_cookie(conn, on?), else: conn
  end

  # The browser pipeline's session plug fetches the cookies with the session;
  # an API request (no jar to keep in step) and a test conn with an injected
  # session (`init_test_session/2` fetches no cookies) both stay Unfetched.
  defp cookies_fetched?(conn), do: not match?(%Plug.Conn.Unfetched{}, conn.req_cookies)

  defp sync_cookie(conn, on?) do
    name = LowBandwidth.cookie_name()

    case {on?, conn.req_cookies[name]} do
      {true, "1"} -> conn
      {false, nil} -> conn
      {true, _absent} -> put_resp_cookie(conn, name, "1", cookie_opts())
      {false, _stale} -> delete_resp_cookie(conn, name, cookie_opts())
    end
  end

  # `Secure` follows the configured scheme the way the session cookie's does
  # (`VutuvWeb.Endpoint.session_options/1`): behind nginx `conn.scheme` is
  # `:http`, so Plug's own default would ship it without the flag.
  defp cookie_opts do
    [
      max_age: @cookie_max_age,
      http_only: true,
      same_site: "Lax",
      secure: VutuvWeb.Endpoint.secure_cookies?()
    ]
  end

  defp session_fetched?(conn), do: match?(%{plug_session_fetch: :done}, conn.private)

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
    if session_fetched?(conn), do: put_session(conn, key, value), else: conn
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
