defmodule Vutuv.SocialFeed.Http do
  @moduledoc """
  The one HTTP surface of the profile's remote-account fetches: hard
  timeouts, capped bodies, and the guarded server-side avatar fetch, shared
  by the social-feed clients (`Vutuv.Mastodon`, `Vutuv.Bluesky`) and the
  code-forge stats clients (`Vutuv.CodeStats.*`).

  Every function takes the provider's req-options key (`:mastodon_req_options`
  / `:bluesky_req_options` / `:github_req_options` / …), the application-env
  seam the tests stub a `plug:` through — per provider, so a test never
  intercepts the other network's requests by accident.
  """

  # A response larger than this is discarded unparsed (untrusted server).
  @max_body_bytes 2_000_000

  # The account avatar, embedded as a data URI. Both networks serve resized
  # avatars, typically well under 100 KB.
  @max_avatar_bytes 1_000_000
  @avatar_types ~w(image/png image/jpeg image/webp image/gif image/avif)

  @doc """
  A plain GET with the clients' shared guard rails: ~2 s to connect, 4 s to
  respond, no retries, no redirects, undecoded body. A slower server is a
  failure that backs off, not one we hang on or hammer. `extra` lets a client
  override single options (the GitHub client swaps the headers for its
  API-versioned, optionally token-carrying set); the env seam still wins, so
  tests always intercept.
  """
  def get(url, options_key, extra \\ []) do
    [
      url: url,
      receive_timeout: 4_000,
      connect_options: [timeout: 2_000],
      retry: false,
      redirect: false,
      decode_body: false,
      headers: [{"user-agent", user_agent()}, {"accept", "application/json"}]
    ]
    |> Keyword.merge(extra)
    |> Keyword.merge(Application.get_env(:vutuv, options_key, []))
    |> Req.get()
  end

  @doc "Decodes a JSON body, refusing oversized answers unparsed."
  def decode(body) when is_binary(body) and byte_size(body) <= @max_body_bytes,
    do: Jason.decode(body)

  def decode(_body), do: {:error, :too_large}

  @doc """
  Fetches an account avatar server-side and returns it as a `data:` URI. The
  URL comes from the remote server's JSON, so it gets the full guard rail:
  https only, an SSRF-vetted host, a real image content type, capped size.
  Fetched server-side so visitors' browsers never contact the remote network;
  any failure means "no avatar" (the template falls back to the initials
  tile), never a failed feed.
  """
  def fetch_avatar(nil, _options_key), do: nil

  def fetch_avatar(url, options_key) do
    with %URI{scheme: "https", host: host} when is_binary(host) <- URI.parse(url),
         false <- Vutuv.Ssrf.resolves_to_internal?(host),
         {:ok, %Req.Response{status: 200, body: body} = resp} <- get(url, options_key),
         type when type in @avatar_types <- content_type(resp),
         true <- is_binary(body) and byte_size(body) <= @max_avatar_bytes do
      "data:" <> type <> ";base64," <> Base.encode64(body)
    else
      _ -> nil
    end
  rescue
    _error -> nil
  end

  defp content_type(resp) do
    case Req.Response.get_header(resp, "content-type") do
      [value | _] -> value |> String.split(";") |> hd() |> String.trim() |> String.downcase()
      _ -> nil
    end
  end

  @doc """
  vutuv's outbound `User-Agent` string, `vutuv/<vsn> (+<public_url>)`. Shared
  by the social-feed clients and the fediverse client so every outbound request
  identifies the installation the same way.
  """
  def user_agent do
    public_url =
      Application.get_env(:vutuv, VutuvWeb.Endpoint)[:public_url] || "https://vutuv.de/"

    "vutuv/#{Application.spec(:vutuv, :vsn)} (+#{String.trim_trailing(public_url, "/")})"
  end
end
