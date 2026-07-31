defmodule Vutuv.EndpointHostHelper do
  @moduledoc """
  Dresses the test endpoint in a real hostname for the duration of one test.

  Every "is this address on this very installation?" gate compares against
  `VutuvWeb.Endpoint.host()`, and the test endpoint answers "localhost" — not a
  valid Fediverse host at all (no dot), so those gates can never fire without
  this. Phoenix caches the endpoint config, so the app env alone is not enough:
  `config_change/2` is what re-reads it.

  The endpoint is global state the SQL sandbox does not roll back, so a test
  module using this must be `async: false`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  def with_endpoint_host(host) do
    original = Application.get_env(:vutuv, VutuvWeb.Endpoint)
    changed = Keyword.put(original, :url, Keyword.put(original[:url] || [], :host, host))

    Application.put_env(:vutuv, VutuvWeb.Endpoint, changed)
    VutuvWeb.Endpoint.config_change([{VutuvWeb.Endpoint, changed}], [])

    on_exit(fn ->
      Application.put_env(:vutuv, VutuvWeb.Endpoint, original)
      VutuvWeb.Endpoint.config_change([{VutuvWeb.Endpoint, original}], [])
    end)
  end
end
