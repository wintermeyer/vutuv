defmodule VutuvWeb.Admin.ExperimentController do
  @moduledoc """
  The readout of the landing-page headline split test (`Vutuv.Experiments`):
  what each variant was shown for, what it earned, and whether the difference
  is worth acting on yet.

  Read-only on purpose. Ending the test means picking the winning copy and
  deleting the loser from `VutuvWeb.PageHTML.founder_quote/1`, which is a
  deploy, not a button — a headline should not be switchable from a dashboard
  by a mis-click.
  """

  use VutuvWeb, :controller

  alias Vutuv.Experiments

  def index(conn, _params) do
    render(conn, "index.html",
      page_title: gettext("Landing page headline test"),
      report: Experiments.report(),
      enabled?: Experiments.enabled?(),
      min_signups: Experiments.min_signups()
    )
  end
end
