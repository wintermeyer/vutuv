defmodule VutuvWeb.Plug.RequireScope do
  @moduledoc """
  Scope gate for `/api/2.0` endpoints — runs after `VutuvWeb.Plug.ApiV2Auth`:

      plug(VutuvWeb.Plug.RequireScope, "profile:read")

  403s with the missing scope named when the token was not granted it
  (a write scope satisfies its read sibling, see `Vutuv.ApiAuth.Scopes`).
  Unknown scope names fail at compile/boot time, not silently at runtime.
  """

  alias Vutuv.ApiAuth.Scopes
  alias VutuvWeb.ApiV2.Problem

  def init(scope) when is_binary(scope) do
    Scopes.valid?(scope) || raise(ArgumentError, "unknown API scope: #{inspect(scope)}")
    scope
  end

  def call(conn, scope) do
    if Scopes.granted?(conn.assigns.api_scopes, scope) do
      conn
    else
      Problem.send_problem(conn, 403, "Missing scope",
        detail: "This endpoint needs the \"#{scope}\" scope, which this token was not granted.",
        extra: %{required_scope: scope}
      )
    end
  end
end
