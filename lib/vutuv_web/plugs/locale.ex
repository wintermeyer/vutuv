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

  # Reduces list of locales to either a supported locale or a {nil, false} tuple
  defp get_supported_locale(locales) do
    Enum.reduce([{nil, false} | locales], fn f, acc ->
      case acc do
        {_, false} -> check_locale_support(f)
        {_, true} -> acc
      end
    end)
    # Check to see if supported locale was found
    |> process_possible_locale(locales)
  end

  defp check_locale_support(f) do
    locale =
      String.split(f, ";")
      |> hd
      |> String.split("-")
      |> hd

    if locale_supported?(locale), do: {locale, true}, else: {nil, false}
  end

  # If supported locale found, return it
  defp process_possible_locale({locale, true}, _), do: locale

  # Else return the user's most preferred locale
  defp process_possible_locale(_, locales), do: get_first_locale(locales)

  defp assign_locale(nil, conn), do: assign(conn, :locale, "en")

  # Give locale data to all modules that require it
  defp assign_locale(locale, conn) do
    Gettext.put_locale(VutuvWeb.Gettext, locale)
    assign(conn, :locale, locale)
  end

  defp get_first_locale([]), do: nil

  # Gets the first locale provided
  defp get_first_locale(locales) do
    locales
    |> hd
    |> String.split("-")
    |> hd
  end

  def locale_supported?(nil), do: false

  # Checks locale provided against app config for supported locales
  def locale_supported?(locale) do
    {:ok, config} = Application.fetch_env(:vutuv, VutuvWeb.Endpoint)
    supported_locales = config[:locales]
    Enum.any?(supported_locales, fn f -> String.contains?(locale, f) end)
  end
end
