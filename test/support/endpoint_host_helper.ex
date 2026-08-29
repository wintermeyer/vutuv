defmodule Vutuv.EndpointHostHelper do
  @moduledoc """
  Swaps endpoint config for the duration of one test, hostname most often.

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
    url = Application.get_env(:vutuv, VutuvWeb.Endpoint)[:url] || []

    with_endpoint_config(:url, Keyword.put(url, :host, host))
  end

  @doc """
  The same swap for any other endpoint key, restored on exit.

  `:cache_static_manifest_latest` is the one the update bar's test needs — it is
  what `static_changed?/1` compares a browser's reported bundle against, and the
  test endpoint has none, so that gate can never answer "changed" without this.
  Same `config_change/2` subtlety, so it lives here rather than being written
  out a second time.
  """
  def with_endpoint_config(key, value) do
    original = Application.get_env(:vutuv, VutuvWeb.Endpoint)

    put_endpoint_config(Keyword.put(original, key, value))
    on_exit(fn -> put_endpoint_config(original) end)
  end

  defp put_endpoint_config(config) do
    Application.put_env(:vutuv, VutuvWeb.Endpoint, config)
    VutuvWeb.Endpoint.config_change([{VutuvWeb.Endpoint, config}], [])
  end
end
