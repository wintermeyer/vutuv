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

  # The machine-readable twin of `@compatibility_version` (Mastodon 4.3+): one
  # integer that says which API generation this speaks, and the value Mastodon
  # itself shipped under the version above (`lib/mastodon/version.rb` at
  # v4.4.0). It exists **because** the version string is unparseable for a fork
  # — ours reads `4.4.0 (compatible; vutuv 7.x)` — so a client that wants to
  # know what it may call reads this instead of guessing at prose. Kept beside
  # the string it belongs to, so the two claims cannot drift into naming
  # different Mastodon generations.
  @mastodon_api_version 6

  def compatibility_version do
    vutuv_version = Application.spec(:vutuv, :vsn) |> to_string()
    @compatibility_version <> " (compatible; vutuv " <> vutuv_version <> ")"
  end

  @doc """
  The `api_versions` object of the v2 instance document.

  A map rather than the bare integer, because the field is an open namespace:
  Mastodon fills `mastodon`, and another implementation may add its own key
  beside it without either side having to agree first.
  """
  def api_versions, do: %{mastodon: @mastodon_api_version}

  @doc """
  Where to write about this installation — the address `security.txt` already
  publishes as the operator contact, from the operator-identity block in
  `config/config.exs` (env-overridable) rather than from a literal here.
  """
  def operator_email do
    {_name, email} = Application.fetch_env!(:vutuv, :operator_recipient)
    email
  end

  @doc """
  The handle of the member a client should be pointed at for this installation,
  as written in config and **not** resolved here: an installation whose handle
  names nobody must answer with no account rather than with a stranger's
  profile, and that is the caller's lookup to make.
  """
  def operator_handle, do: Application.get_env(:vutuv, :operator_handle)

  @doc """
  An absolute URL on the main host. `query` is passed separately because
  `absolute_url/3` builds the URI from parts — a query folded into `path`
  would be escaped into the path rather than kept as one.
  """
  def main_url(path, query \\ nil), do: absolute_url(local_domain(), path, query)

  def api_url(path), do: absolute_url(api_host(), path, nil)

  @doc """
  The streaming endpoint as a client must dial it: the `ws(s)` form of
  `client_url/2`, on the host this request arrived on.

  Named on the caller's host for the same reason every other endpoint is — a
  client that signed in on the main host would drop its bearer token crossing
  to the subdomain, and the streaming socket authenticates with that token.
  """
  def streaming_url(host) do
    host
    |> client_url("/api/v1/streaming")
    |> String.replace_prefix("https://", "wss://")
    |> String.replace_prefix("http://", "ws://")
  end

  defp absolute_url(host, path, query) do
    uri = URI.parse(Endpoint.url())
    URI.to_string(%{uri | host: host, path: path, query: query, fragment: nil})
  end
end
