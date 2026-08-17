defmodule Vutuv.MastodonApi do
  @moduledoc """
  Installation-level configuration and URL helpers for the Mastodon-compatible
  client API served from `mastodon.<PHX_HOST>`.

  The member and ActivityPub identities stay on the main host. Only the REST
  adapter and its OAuth machine endpoints live on the technical subdomain.
  """

  alias VutuvWeb.Endpoint

  @compatibility_version "4.4.0"

  def enabled?, do: Application.get_env(:vutuv, :mastodon_api_enabled, true)

  def local_domain, do: Endpoint.host()
  def api_host, do: "mastodon." <> local_domain()

  @doc """
  Whether `host` may serve the client API — the technical subdomain **or** the
  main host.

  The subdomain is the canonical origin and the one this app advertises, but a
  member typing an address into a phone app types the address they know, which
  is the main one. Serving both is what makes `vutuv.de` work as a login.

  A redirect would have been the smaller change and does not survive contact
  with a real client: an app keeps the host you typed and builds every later
  URL from it, and HTTP libraries drop the `Authorization` header on a
  cross-host redirect — so the login would complete and every authenticated
  call after it would come back 401. Both hosts answer the same routes
  instead.
  """
  def client_host?(host) when is_binary(host),
    do: normalize_host(host) in [api_host(), local_domain(), "www." <> local_domain()]

  def client_host?(_host), do: false

  # A host arrives however the client wrote it: shouted, with the trailing dot
  # of a fully-qualified name. Every test against a host we own goes through
  # here, so none of them can be the one that forgets.
  defp normalize_host(host),
    do: host |> to_string() |> String.downcase() |> String.trim_trailing(".")

  @doc """
  The origin a client should keep talking to, given the host it reached us on.

  A client that found us at the main host stays there; one that used the
  subdomain stays there too. Sending it across hosts mid-flow is what breaks
  the bearer token.
  """
  def client_url(host, path) do
    if normalize_host(host) == api_host(), do: api_url(path), else: main_url(path)
  end

  def compatibility_version do
    vutuv_version = Application.spec(:vutuv, :vsn) |> to_string()
    @compatibility_version <> " (compatible; vutuv " <> vutuv_version <> ")"
  end

  def main_url(path), do: absolute_url(local_domain(), path)
  def api_url(path), do: absolute_url(api_host(), path)

  defp absolute_url(host, path) do
    uri = URI.parse(Endpoint.url())
    URI.to_string(%{uri | host: host, path: path, query: nil, fragment: nil})
  end
end
