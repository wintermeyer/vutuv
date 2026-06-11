defmodule VutuvWeb.ApiV1.NotFoundController do
  @moduledoc """
  The `/api/v1` catch-all: unknown API paths answer with a problem+json
  404 instead of falling through to the HTML profile routes. Also the
  route the CORS preflight matches (`VutuvWeb.Plug.ApiCors` answers
  OPTIONS before this action runs).
  """

  use VutuvWeb, :controller

  alias VutuvWeb.ApiV1.Problem

  def show(conn, _params) do
    Problem.not_found(conn, "Unknown API route. See /developers for the reference.")
  end
end
