defmodule VutuvWeb.ApiV1 do
  @moduledoc """
  Shared response helper for the `/api/v1` controllers: success bodies are
  the same doc maps the public AgentDocs `.json` siblings serve (rendered
  by `VutuvWeb.AgentDocs.JSON`), so the authenticated API and the anonymous
  JSON pages speak one schema. Errors are `VutuvWeb.ApiV1.Problem`.
  """

  import Plug.Conn

  alias VutuvWeb.AgentDocs.JSON

  def send_json(conn, doc, status \\ 200) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.render(doc))
  end
end
