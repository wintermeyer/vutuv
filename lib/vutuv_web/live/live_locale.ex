defmodule VutuvWeb.LiveLocale do
  @moduledoc """
  Sets the Gettext locale inside a LiveView process.

  `VutuvWeb.Plug.Locale` resolves the locale per request (user preference,
  then Accept-Language) and stores it in the session. LiveViews run in their
  own process, so every mount has to re-apply it — otherwise the chrome and
  page copy silently fall back to English on live pages.
  """

  alias Vutuv.Accounts.User

  @doc "Apply the user's (or session's) locale to the current process."
  def put_locale(user \\ nil, session)

  def put_locale(%User{locale: locale}, _session) when is_binary(locale) and locale != "" do
    Gettext.put_locale(VutuvWeb.Gettext, locale)
  end

  def put_locale(_user, session) do
    Gettext.put_locale(VutuvWeb.Gettext, session["locale"] || "en")
  end
end
