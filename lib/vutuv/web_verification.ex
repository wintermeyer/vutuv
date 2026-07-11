defmodule Vutuv.WebVerification do
  @moduledoc """
  The web-proof primitives shared by verified organization pages
  (`Vutuv.Organizations.Verification`, issue #929) and verified personal-webpage
  links (`Vutuv.Profiles.LinkVerification`). Each primitive proves control of a
  web resource without any assumption about who owns it:

    * `dns` — a `<prefix><token>` TXT record on a host.
    * `well_known` — the token served at a `.well-known` path on the host.
    * `rel_me` — the page links back to a given URL with `rel="me"` (the
      IndieWeb / Mastodon standard, which needs no token: the back-link target
      is itself the proof).

  The primitives are **config-agnostic**: the DNS prefix, the `.well-known`
  path, the DNS resolver and the `Req` options are all passed in by the caller,
  so each context keeps its own verification scheme, its own test seam and its
  own outbound-call gate (`:verify_organization_domains` / `:verify_user_links`).
  Organizations use `vutuv-organization-verify=` / `/.well-known/vutuv-organization-verify.txt`
  and personal-webpage links use `vutuv-verify=` / `/.well-known/vutuv-verify.txt`,
  so a proof for one context never doubles as a proof for the other. The
  `well_known` and `rel_me` fetches run behind the `Vutuv.Ssrf` guard and never
  follow redirects.
  """

  require Logger

  alias Vutuv.Ssrf

  @max_well_known_bytes 4_096
  # rel=me links can sit anywhere in the page (a footer, an "about" sidebar), so
  # more of the body must be scanned than for the tiny well-known file, but a
  # cap still bounds a hostile or runaway response.
  @max_html_bytes 512_000

  @doc "A fresh unguessable verification token (~192 bits, URL-safe)."
  def gen_token do
    24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  # --- DNS TXT ----------------------------------------------------------------

  @doc "The exact TXT record value (`<prefix><token>`) to publish for the `dns` method."
  def dns_txt_value(prefix, token) when is_binary(prefix) and is_binary(token),
    do: prefix <> token

  @doc """
  Whether `host` publishes a `<prefix><token>` TXT record. `resolver` is a
  `fun(host) -> [txt_record]` where each record is a list of charlist chunks
  (the shape `:inet_res.lookup/3` returns).
  """
  def dns_verified?(host, prefix, token, resolver)
      when is_binary(host) and is_binary(prefix) and is_binary(token) and
             is_function(resolver, 1) do
    expected = dns_txt_value(prefix, token)
    Enum.any?(txt_records(host, resolver), &(&1 == expected))
  end

  defp txt_records(host, resolver) do
    host
    |> resolver.()
    |> Enum.map(fn parts -> Enum.map_join(parts, "", &to_string/1) end)
  rescue
    _ -> []
  end

  @doc "The default DNS TXT resolver (`:inet_res.lookup/3`)."
  def default_txt_lookup(host) do
    :inet_res.lookup(to_charlist(host), :in, :txt)
  end

  # --- well-known file --------------------------------------------------------

  @doc "The URL fetched for the `well_known` method (host + the given `.well-known` path)."
  def well_known_url(host, path) when is_binary(host) and is_binary(path),
    do: "https://" <> host <> path

  @doc """
  Whether `https://host<path>` serves exactly `token`. SSRF-guarded and never
  follows redirects. `req_options` is merged into the `Req.get/1` options (the
  test seam).
  """
  def well_known_verified?(host, path, token, req_options)
      when is_binary(host) and is_binary(path) and is_binary(token) do
    case fetch(well_known_url(host, path), host, req_options, @max_well_known_bytes, "text/plain") do
      {:ok, body} -> String.trim(body) == token
      {:error, _} -> false
    end
  end

  # --- rel=me back-link -------------------------------------------------------

  @doc """
  Whether the page at `url` links back to any of `expected_urls` with `rel="me"`.
  Fetches the page (SSRF-guarded, no redirects, size-capped), then scans it for
  an `<a>` / `<link>` tag whose `rel` contains the `me` token and whose `href`
  resolves to an expected URL. `req_options` is the test seam.
  """
  def rel_me_verified?(url, expected_urls, req_options)
      when is_binary(url) and is_list(expected_urls) do
    with %URI{host: host} when is_binary(host) <- URI.parse(url),
         {:ok, body} <- fetch(url, host, req_options, @max_html_bytes, "text/html") do
      wanted = MapSet.new(expected_urls, &normalize_url/1)

      body
      |> rel_me_hrefs()
      |> Enum.any?(&MapSet.member?(wanted, normalize_url(&1)))
    else
      _ -> false
    end
  end

  @tag_regex ~r/<(?:a|link)\b[^>]*>/i

  @doc "Every `href` on an `<a>` / `<link>` tag whose `rel` includes `me`."
  def rel_me_hrefs(html) when is_binary(html) do
    @tag_regex
    |> Regex.scan(html)
    |> Enum.map(&List.first/1)
    |> Enum.filter(&rel_me_tag?/1)
    |> Enum.map(&attr(&1, "href"))
    |> Enum.reject(&is_nil/1)
  end

  defp rel_me_tag?(tag) do
    case attr(tag, "rel") do
      nil -> false
      rel -> rel |> String.downcase() |> String.split(~r/\s+/, trim: true) |> Enum.member?("me")
    end
  end

  # Reads one HTML attribute value, tolerating double / single / unquoted forms
  # and arbitrary attribute order. Returns nil when absent or empty.
  defp attr(tag, name) do
    regex = ~r/\b#{name}\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/i

    case Regex.run(regex, tag) do
      nil -> nil
      [_ | groups] -> Enum.find(groups, &(&1 not in [nil, ""]))
    end
  end

  @doc """
  Reduces a URL to a scheme-insensitive `host/path` key for comparison: downcase
  the host, drop a leading `www.`, drop the scheme and query, strip a trailing
  slash. A relative URL (no host) keeps its path, so it never matches an
  absolute expected URL.
  """
  def normalize_url(url) do
    uri = URI.parse(String.trim(to_string(url)))

    host =
      (uri.host || "")
      |> String.downcase()
      |> String.replace_prefix("www.", "")

    path = (uri.path || "") |> String.trim_trailing("/")

    host <> path
  end

  # --- shared fetch -----------------------------------------------------------

  defp fetch(url, host, req_options, max_bytes, accept) do
    if Ssrf.resolves_to_internal?(host) do
      {:error, :ssrf}
    else
      request(url, req_options, max_bytes, accept)
    end
  end

  defp request(url, req_options, max_bytes, accept) do
    options =
      [
        url: url,
        receive_timeout: 4_000,
        connect_options: [timeout: 2_000],
        retry: false,
        redirect: false,
        decode_body: false,
        headers: [{"user-agent", user_agent()}, {"accept", accept}]
      ]
      |> Keyword.merge(req_options)

    case Req.get(options) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, binary_part(body, 0, min(byte_size(body), max_bytes))}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      Logger.warning("web verification fetch failed for #{url}: #{inspect(error)}")
      {:error, :exception}
  end

  defp user_agent do
    vsn = Application.spec(:vutuv, :vsn) || ~c"0"
    "vutuv/#{vsn} (+#{VutuvWeb.Endpoint.url()})"
  end
end
