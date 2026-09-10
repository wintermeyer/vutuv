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

  # The one connect timeout, shared by `base_options/3`'s `connect_options` and
  # by a pinned request's own Finch instance, which cannot read that keyword.
  @connect_timeout 2_000

  # How many pinned requests may be in flight at once. Built at compile time
  # because the point is that no atom is ever minted at runtime — see
  # `get_pinned/4` for what that costs when it is. Sixteen is far more than the
  # one sequential sweeper that uses this needs, and small enough to be free.
  @pinned_slot_names for n <- 0..15, do: Module.concat(__MODULE__, "Pinned#{n}")

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
    url |> request_options(options_key, extra) |> Req.get()
  end

  @doc """
  The option list `get/3` hands `Req`, assembled but not sent.

  Public because one property of it cannot be observed any other way: a test
  stubs HTTP through a `plug:`, and `Req.Steps.put_plug/1` swaps the adapter out
  **before** the Finch step ever validates its options — so a request that would
  raise against a real server sails through every stubbed test.
  """
  def request_options(url, options_key, extra \\ []) do
    url
    |> base_options()
    |> deep_merge(extra)
    |> deep_merge(Application.get_env(:vutuv, options_key, []))
    |> drop_pool_options()
  end

  # `Req` refuses to be handed both `:finch` and `:connect_options`, and it is
  # the base options that supply the second — so dropping it from the caller's
  # own list is not enough, it has to go from the merged one. A caller naming
  # its own Finch has put every connect setting into that instance's `conn_opts`
  # already, so what goes here is a duplicate, and keeping it is an
  # `ArgumentError` on every real request that a `plug:` test cannot see.
  defp drop_pool_options(options) do
    if Keyword.has_key?(options, :finch),
      do: Keyword.delete(options, :connect_options),
      else: options
  end

  @doc """
  A GET **pinned to the address the host was vetted at**, for a client reading a
  URL somebody else chose.

  `Vutuv.Ssrf.resolves_to_internal?/1` only *checks* the host, and the client
  then hands `Req` the hostname to look up a second time — a lookup that can
  answer with an internal address (DNS rebinding), the TOCTOU
  `Vutuv.Ssrf`'s own moduledoc calls out. Here the request is dialled at exactly
  the IP `vetted_address/1` approved, and the hostname rides along as `Mint`'s
  `:hostname`, which it uses for SNI, for certificate verification and for the
  `Host` header — so there is no second lookup to poison, and the remote server
  still sees the virtual host it is asked about.

  **The connection is opened and closed for this one request, and it borrows one
  of a fixed set of names to do it.** Both halves are the bound. Handing `Req` a
  per-host `connect_options` makes it start a whole `Finch` instance per
  distinct hostname under `Req.FinchSupervisor` and never reap it — measured at
  25 hostnames, 25 instances, about 200 processes — and which hostnames appear
  is decided by what members type into a followed tag's sources. Minting a fresh
  instance *name* per request instead only moves the leak somewhere worse:
  `Finch` derives four more atoms from the name it is given, and atoms are never
  reclaimed (measured: 9 per request, which at this sweeper's own budget is atom
  table exhaustion and a halted VM in about eight days). So the names come from
  `pinned_slot_names/0`, a compile-time list: at most that many pinned requests
  are in flight at once, nothing is minted after the first use of each, and
  every instance is stopped in an `after`.

  The cost is a fresh TLS handshake per fetch, which a background sweeper making
  a handful of requests per host per run can afford.

  `path` is everything after the authority, already escaped. Answers
  `{:error, :internal | :unresolvable}` when the host does not survive the vet,
  and `{:error, :busy}` when every slot is taken.
  """
  def get_pinned(host, path, options_key, extra \\ []) do
    case Vutuv.Ssrf.vetted_address(host) do
      {:ok, address} ->
        url = "https://#{authority(address)}#{path}"

        with_pinned_finch(host, address, fn finch ->
          get(url, options_key, pin(host, finch, extra))
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The request half of the pin: the `Finch` instance to send through, and the
  `Host` header written out so the virtual host is named whatever the transport
  decides. The identity half — the hostname `Mint` verifies the certificate
  against and offers in SNI — is `pinned_pools/2`.
  """
  def pin(host, finch, extra \\ []) do
    deep_merge([finch: finch, headers: [{"host", host}]], extra)
  end

  @doc """
  The identity half of the pin, and the security decision this module exists to
  make assertable: `conn_opts[:hostname]`, which `Mint` uses for SNI, for
  certificate verification and for the default `Host` header, while the socket
  itself goes to the vetted IP in the URL. Drop that one key and both checks
  fall back to the IP literal, with every `plug:`-stubbed test still green.

  It also carries what `Req` would otherwise have derived from
  `connect_options`: HTTP/1 (its own default), the shared connect timeout, and
  the `inet6` flag it infers from a bracketed URL host and cannot pass on to an
  instance it did not start.
  """
  def pinned_pools(host, address) do
    transport = [timeout: @connect_timeout] ++ ipv6_options(address)

    %{default: [protocols: [:http1], conn_opts: [hostname: host, transport_opts: transport]]}
  end

  @doc "The fixed set of names a pinned request may borrow — see `get_pinned/4`."
  def pinned_slot_names, do: @pinned_slot_names

  # Borrow the first free slot, use it, hand it back. `{:already_started, _}`
  # means a concurrent pinned request holds that name, not that anything failed.
  defp with_pinned_finch(host, address, fun) do
    case claim_slot(@pinned_slot_names, host, address) do
      {:ok, name, pid} ->
        try do
          fun.(name)
        after
          Supervisor.stop(pid)
        end

      :busy ->
        {:error, :busy}
    end
  end

  defp claim_slot([], _host, _address), do: :busy

  defp claim_slot([name | rest], host, address) do
    case Finch.start_link(name: name, pools: pinned_pools(host, address)) do
      {:ok, pid} -> {:ok, name, pid}
      {:error, {:already_started, _pid}} -> claim_slot(rest, host, address)
      {:error, _reason} -> :busy
    end
  end

  defp ipv6_options(address) when tuple_size(address) == 8, do: [inet6: true]
  defp ipv6_options(_address), do: []

  # An IPv6 literal needs its brackets back before it can be a URL authority,
  # and `Req` reads exactly that shape to decide it must dial over IPv6.
  defp authority(address) do
    literal = address |> :inet.ntoa() |> to_string()

    if tuple_size(address) == 8, do: "[#{literal}]", else: literal
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
      connect_options: [timeout: @connect_timeout],
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
