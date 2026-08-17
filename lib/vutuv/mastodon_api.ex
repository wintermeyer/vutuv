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
