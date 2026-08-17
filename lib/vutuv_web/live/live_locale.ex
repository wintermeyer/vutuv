defmodule VutuvWeb.LiveLocale do
  @moduledoc """
  Applies the visitor's language and viewer clock inside a LiveView process.

  `VutuvWeb.Plug.Locale` resolves both per request — the interface language and
  the date shape / time zone every timestamp is written in — and stores what a
  socket cannot re-derive in the session. LiveViews run in their own process,
  so every mount has to re-apply them; otherwise the chrome and page copy
  silently fall back to English on live pages.

  Called without a user (the LiveViews embedded outside the `live_session`,
  which resolve their viewer themselves and mostly show no timestamps at all),
  the clock falls back to the browser's date guess from the session and the
  installation's time zone — which is what leaves `VutuvWeb.UI.local_time/1`'s
  client-side rewrite in charge, so the reader still sees their own zone.
  """

  alias Vutuv.Accounts.User
  alias Vutuv.ViewerClock

  @doc "Apply the user's (or session's) language and viewer clock to this process."
  def put_viewer(user \\ nil, session) do
    put_locale(user, session)
    ViewerClock.put_viewer(user, session["date_region"])
  end

  defp put_locale(%User{locale: locale}, _session) when is_binary(locale) and locale != "" do
    Gettext.put_locale(VutuvWeb.Gettext, locale)
  end

  defp put_locale(_user, session) do
    Gettext.put_locale(VutuvWeb.Gettext, session["locale"] || "en")
  end
end
