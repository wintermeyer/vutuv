defmodule VutuvWeb.Plug.RequireAdsEnabled do
  @moduledoc """
  Gate the daily text-ad pages behind the global `:ads_enabled` switch
  (`Vutuv.Ads.enabled?/0`). When the system is off, the public `/ads` flow
  and the admin review dashboard answer a clean 404 - the URLs behave as if
  they did not exist - rather than rendering a feature nobody can use.

  `"ads"` stays a reserved slug regardless (see
  `Vutuv.Accounts.ReservedSlugs`), so the handle is never claimed while the
  system is parked.
  """

  def init(opts), do: opts

  def call(conn, _opts) do
    if Vutuv.Ads.enabled?() do
      conn
    else
      VutuvWeb.ControllerHelpers.render_error(conn, 404)
    end
  end
end
