defmodule VutuvWeb.HealthController do
  use VutuvWeb, :controller

  # Readiness probe for the blue/green deploy (scripts/deploy.sh): the new
  # release only receives traffic after this returns 200. The SELECT 1 makes
  # "up" mean "serving requests AND connected to the database", not merely
  # "the HTTP listener is bound". A failed query crashes the request and the
  # probe sees a 500.
  def index(conn, _params) do
    %{rows: [[1]]} = Vutuv.Repo.query!("SELECT 1")

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok")
  end
end
