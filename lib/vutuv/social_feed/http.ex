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

  alias Vutuv.BuildInfo
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Moderation.Ollama

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

  `:headers` and `:connect_options` are merged **per key** rather than replaced,
  because both hold shared settings a client has no business dropping: a client
  adding one header would otherwise lose `user-agent` and introduce this
  installation to a stranger's server as an anonymous HTTP library, and one
  adding `hostname` would lose the connect timeout. That trap was already known
  and only survivable by hand — `Vutuv.CodeStats.GitHub` restates
  `Http.user_agent/0` inside its own header list for exactly this reason.
  """
  def get(url, options_key, extra \\ []) do
    url
    |> base_options()
    |> deep_merge(extra)
    |> deep_merge(Application.get_env(:vutuv, options_key, []))
    |> Req.get()
  end

  @doc """
  A GET **pinned to the address the host was vetted at**, for a client reading a
  URL somebody else chose.

  `Vutuv.Ssrf.resolves_to_internal?/1` only *checks* the host, and the client
  then hands `Req` the hostname to look up a second time — a lookup that can
  answer with an internal address (DNS rebinding), the TOCTOU
  `Vutuv.Ssrf`'s own moduledoc calls out. Here the request is dialled at exactly
  the IP `vetted_address/1` approved, and the hostname rides along in
  `connect_options[:hostname]`, which `Mint` uses for SNI, for certificate
  verification and for the `Host` header — so there is no second lookup to
  poison, and the remote server still sees the virtual host it is asked about.

  `path` is everything after the authority, already escaped. Answers
  `{:error, :internal | :unresolvable}` when the host does not survive the vet.
  """
  def get_pinned(host, path, options_key, extra \\ []) do
    case Vutuv.Ssrf.vetted_address(host) do
      {:ok, address} ->
        get("https://#{authority(address)}#{path}", options_key, pin(host, extra))

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The options that pin a request to a vetted address: the hostname `Mint` must
  use, and the `Host` header written out beside it. Public so the pin can be
  asserted on directly — it is a security decision, not an implementation
  detail.
  """
  def pin(host, extra \\ []) do
    deep_merge([connect_options: [hostname: host], headers: [{"host", host}]], extra)
  end

  # An IPv6 literal needs its brackets back before it can be a URL authority,
  # and `Req` reads exactly that shape to decide it must dial over IPv6.
  defp authority(address) do
    literal = address |> :inet.ntoa() |> to_string()

    if String.contains?(literal, ":"), do: "[#{literal}]", else: literal
  end

  # Keyword options replace, except the two that carry shared settings: those
  # are merged key by key, so `extra` overrides what it names and keeps the rest.
  defp deep_merge(options, extra) do
    Keyword.merge(options, extra, fn
      :headers, base, override -> merge_headers(base, override)
      :connect_options, base, override -> Keyword.merge(base, override)
      _key, _base, override -> override
    end)
  end

  defp merge_headers(base, override) do
    named = Enum.map(override, fn {name, _value} -> String.downcase(name) end)

    Enum.reject(base, fn {name, _value} -> String.downcase(name) in named end) ++ override
  end

  @doc """
  The guard rails themselves, for a caller that resolves its own env seam and
  needs its own body cap and `accept` (`Vutuv.WebVerification`, which reads a
  member's own web page rather than an API).

  Split out because that caller had grown its own copy of this list, down to
  the comment on `decode_body:` — and the two copies had already drifted on the
  one line that must not, the `User-Agent`, so one installation named itself
  two ways depending on which of its own requests you looked at.
  """
  def base_options(url, max_bytes \\ @max_body_bytes, accept \\ "application/json") do
    [
      url: url,
      receive_timeout: 4_000,
      connect_options: [timeout: 2_000],
      retry: false,
      redirect: false,
      # The callers decode the body themselves behind `is_binary` guards, so
      # Req's own decode step must stay off — `into:` does NOT imply that (it
      # still runs over the collected body, and the real APIs answer
      # `application/json`); losing this line broke every fetch in v7.95.4.
      decode_body: false,
      # Stream with a hard ceiling so a hostile large body is dropped during
      # receipt; the per-use post-checks (decode/1, fetch_avatar/2) still enforce
      # their exact JSON / avatar limits.
      into: Vutuv.Http.capped_collector(max_bytes),
      headers: [{"user-agent", user_agent()}, {"accept", accept}]
    ]
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
         true <- is_binary(body) and byte_size(body) <= @max_avatar_bytes,
         true <- safe_remote_image?(body) do
      "data:" <> type <> ";base64," <> Base.encode64(body)
    else
      _ -> nil
    end
  rescue
    _error -> nil
  end

  # Remote member-chosen imagery goes through the same AI safety gate as
  # uploads (Vutuv.Moderation.ImageScans would otherwise have a bypass: point
  # your Mastodon/Bluesky avatar at anything and it shows on your profile
  # card). Fail-closed: an unsafe or unjudgeable image (or Ollama being down)
  # means "no avatar" — the card falls back to the initials tile. The verdict
  # rides the feed cache entry (Vutuv.SocialFeed.Cache), so it is re-checked
  # on every re-fetch, never persisted.
  defp safe_remote_image?(body) do
    not ImageScans.enabled?() or
      match?({:ok, %{safe?: true}}, Ollama.moderate_binary(body))
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

    "vutuv/#{BuildInfo.version()} (+#{String.trim_trailing(public_url, "/")})"
  end

  @doc """
  True when `user_agent` is a vutuv installation's outbound agent — this one or
  anybody else's, since only the version and the public URL differ.

  The headless page-capture browser sends it too
  (`Vutuv.PageScreenshot.capture_args/1`), which is how a page can tell that it
  is being screenshotted rather than read, and skip on-arrival behaviour that
  would spoil the shot (the post permalink's scroll jump, issue #1033).
  """
  def own_agent?("vutuv/" <> _rest), do: true
  def own_agent?(_user_agent), do: false
end
