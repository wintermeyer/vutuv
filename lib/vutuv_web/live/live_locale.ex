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
  alias Vutuv.LowBandwidth
  alias Vutuv.ViewerClock

  @doc """
  Apply the user's (or session's) language, viewer clock and data-saving
  mode to this process. Called without a user, the mode is the installation
  default — the same answer the plug gives a logged-out visitor — and the
  LiveViews that mount that way show no picture that has a lite version.

  **An embedded child calls this on the socket alone, never on its dead
  render.** The children the app layout embeds (`VutuvWeb.ShellLive` at its
  top, `PostLive.Actions`, `SectionReorderLive`, `ReferenceCheckLive`) mount
  in the request process on the dead render, before the page body's own
  expressions run — layout dynamics evaluate in document order — and that
  process already holds the plug's answer for the member whose page it is.
  Resolving "nobody" there overwrote it: every first paint of a LiveView page
  carried the installation's time zone and the full-size pictures, and only
  the socket's re-render put the member's own zone and the lite versions in
  (`live_locale_dead_render_test.exs`). A connected socket is a fresh process
  and resolves for itself, as every routed LiveView does through
  `VutuvWeb.Live.InitAssigns`.
  """
  def put_viewer(user \\ nil, session) do
    put_locale(user, session)
    ViewerClock.put_viewer(user, session["date_region"])
    LowBandwidth.put_viewer(user)
    :ok
  end

  defp put_locale(%User{locale: locale}, _session) when is_binary(locale) and locale != "" do
    Gettext.put_locale(VutuvWeb.Gettext, locale)
  end

  defp put_locale(_user, session) do
    Gettext.put_locale(VutuvWeb.Gettext, session["locale"] || "en")
  end
end
