defmodule VutuvWeb.Plug.Locale do
  @moduledoc false

  import Plug.Conn

  def init(default), do: default

  def call(conn, _default) do
    handle_locale(conn, conn.assigns[:current_user])
  end

  defp handle_locale(conn, %Vutuv.Accounts.User{locale: nil}), do: handle_locale(conn, nil)

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

  defp handle_locale(conn, %Vutuv.Accounts.User{locale: loc}) do
    assign_locale(loc, conn)
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
    |> store_in_session(locale)
  end

  # API requests run this plug without a fetched session — skip them.
  defp store_in_session(conn, locale) do
    case conn.private do
      %{plug_session_fetch: :done} -> put_session(conn, :locale, locale)
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
  def locale_supported?(locale) do
    {:ok, config} = Application.fetch_env(:vutuv, VutuvWeb.Endpoint)
    supported_locales = config[:locales]
    locale in supported_locales
  end
end
