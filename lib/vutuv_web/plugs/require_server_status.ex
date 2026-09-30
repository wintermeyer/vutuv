defmodule VutuvWeb.Plug.RequireServerStatus do
  @moduledoc """
  Gate `/system/status` behind `:server_status_enabled`
  (`Vutuv.ServerStatus.enabled?/0`). An installation that switched the page off
  answers a clean 404, as if the URL had never existed; the footer drops its
  link by the same switch.
  """

  def init(opts), do: opts

  def call(conn, _opts) do
    if Vutuv.ServerStatus.enabled?(),
      do: conn,
      else: VutuvWeb.ControllerHelpers.render_error(conn, 404)
  end
end
