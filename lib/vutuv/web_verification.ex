defmodule Vutuv.WebVerification do
  @moduledoc """
  The web-proof primitives shared by verified organization pages
  (`Vutuv.Organizations.Verification`, issue #929) and verified personal-webpage
  links (`Vutuv.Profiles.LinkVerification`). Each primitive proves control of a
  web resource without any assumption about who owns it:

    * `dns` — a `<prefix><token>` TXT record, published either on the host
      itself or on the CNAME-safe `_vutuv.<host>` alternate name (see
      `dns_challenge_name/1`).
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

  alias Vutuv.Dns
  alias Vutuv.SocialFeed.Http
  alias Vutuv.Ssrf

  # How much of an unexpected answer is quoted back to the member in a check
  # report. Enough to recognise the record or page they published by mistake,
  # short enough that a hostile body cannot fill their screen.
  @max_excerpt 160

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

  # A CNAME and a TXT record cannot coexist on the same DNS name (RFC 1034), so a
  # host that is itself a CNAME (a hosted page such as `changelog.example.org` →
  # `tharg.host.example`, a redirect) has no place for a bare-host TXT record —
  # the provider rejects it and a TXT query just follows the CNAME to the target.
  # We therefore also accept the record at an underscore-prefixed alternate name,
  # the `_dmarc` / `_acme-challenge` convention (RFC 8552): an underscore label is
  # never a CNAME target, so a member can always publish the record there.
  @dns_challenge_label "_vutuv"

  @doc "The exact TXT record value (`<prefix><token>`) to publish for the `dns` method."
  def dns_txt_value(prefix, token) when is_binary(prefix) and is_binary(token),
    do: prefix <> token

  @doc """
  The CNAME-safe alternate name (`_vutuv.<host>`) a `dns` TXT record may also
  live at, for a host that is itself a CNAME and so cannot carry a bare-host TXT
  record.
  """
  def dns_challenge_name(host) when is_binary(host), do: @dns_challenge_label <> "." <> host

  @doc """
  Whether a `<prefix><token>` TXT record is published for `host` — on the host
  itself or on its CNAME-safe `_vutuv.<host>` alternate name. `resolver` is a
  `fun(host) -> [txt_record]` where each record is a list of charlist chunks
  (the shape `:inet_res.lookup/3` returns).
  """
  def dns_verified?(host, prefix, token, resolver)
      when is_binary(host) and is_binary(prefix) and is_binary(token) and
             is_function(resolver, 1) do
    match?({:ok, _report}, dns_check(host, prefix, token, resolver))
  end

  @doc """
  The `dns` check plus a report of what was actually read: which names were
  queried, the value we wanted, and **every** TXT record we saw there.

  The report is the whole point of this function existing beside
  `dns_verified?/4`. A bare "not found yet" leaves a member re-reading their own
  zone file; being told that we see their SPF record and their Google
  verification but not ours tells them in one line that they published to the
  wrong name, or with a typo, or on a zone that is not the live one.
  """
  def dns_check(host, prefix, token, resolver)
      when is_binary(host) and is_binary(prefix) and is_binary(token) and
             is_function(resolver, 1) do
    expected = dns_txt_value(prefix, token)
    names = [host, dns_challenge_name(host)]

    # The bare host is read first and a hit stops there, so the common
    # (non-CNAME) case still verifies in a single lookup and only a miss pays
    # for the second, alternate-name query — the one that then also fills the
    # report.
    {found, matched?} =
      Enum.reduce_while(names, {[], false}, fn name, {seen, _matched?} ->
        records = txt_records(name, resolver)

        if expected in records do
          {:halt, {seen ++ records, true}}
        else
          {:cont, {seen ++ records, false}}
        end
      end)

    report = %{
      method: "dns",
      names: names,
      expected: expected,
      found: found |> Enum.uniq() |> Enum.map(&excerpt/1)
    }

    if matched?, do: {:ok, report}, else: {:error, report}
  end

  defp txt_records(host, resolver) do
    host
    |> resolver.()
    |> Enum.map(fn parts -> Enum.map_join(parts, "", &to_string/1) end)
  rescue
    _ -> []
  end

  @doc """
  The default DNS TXT resolver. Reads the record from the zone's **own** name
  servers where it can reach them (`Vutuv.Dns`), because a recursive resolver
  answers a freshly published record from its negative cache for the zone's
  negative TTL — hours, in the case that produced issue #1466.
  """
  def default_txt_lookup(host) do
    Dns.txt_records(host)
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
    match?({:ok, _report}, well_known_check(host, path, token, req_options))
  end

  @doc """
  The `well_known` check plus a report of what the fetch actually got: the URL,
  the HTTP status, and the first line of the body when there was one.

  One fetch answers both halves, so a failing check costs no more than it did
  before it started explaining itself. `status: nil` means the request never
  produced a response at all (DNS, TLS, connection, the SSRF guard).
  """
  def well_known_check(host, path, token, req_options)
      when is_binary(host) and is_binary(path) and is_binary(token) do
    url = well_known_url(host, path)

    case fetch(url, host, req_options, @max_well_known_bytes, "text/plain") do
      {:ok, body} ->
        served = String.trim(body)
        report = %{method: "well_known", url: url, status: 200, found: excerpt(served)}

        if served == token, do: {:ok, report}, else: {:error, report}

      {:error, {:status, status}} ->
        {:error, %{method: "well_known", url: url, status: status, found: nil}}

      {:error, _reason} ->
        {:error, %{method: "well_known", url: url, status: nil, found: nil}}
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
    match?({:ok, _report}, rel_me_check(url, expected_urls, req_options))
  end

  @doc """
  The `rel_me` check plus a report of what the fetch actually got: the URL, the
  HTTP status, the back-link we wanted and **every** `rel="me"` link the page
  carries.

  Listing the links that are there is the diagnosis. `rel="me"` is a set, not a
  single value, and the common failure is a page that already points at a
  GitHub or Mastodon profile and simply does not name this one yet — which
  reads as "verification is broken" until somebody says what was on the page.
  """
  def rel_me_check(url, expected_urls, req_options)
      when is_binary(url) and is_list(expected_urls) do
    with %URI{host: host} when is_binary(host) <- URI.parse(url),
         {:ok, body} <- fetch(url, host, req_options, @max_html_bytes, "text/html") do
      wanted = MapSet.new(expected_urls, &normalize_url/1)
      hrefs = rel_me_hrefs(body)
      report = rel_me_report(url, expected_urls, 200, Enum.map(hrefs, &excerpt/1))

      if Enum.any?(hrefs, &MapSet.member?(wanted, normalize_url(&1))),
        do: {:ok, report},
        else: {:error, report}
    else
      {:error, {:status, status}} ->
        {:error, rel_me_report(url, expected_urls, status, [])}

      _ ->
        {:error, rel_me_report(url, expected_urls, nil, [])}
    end
  end

  defp rel_me_report(url, expected_urls, status, found) do
    %{
      method: "rel_me",
      url: url,
      status: status,
      expected: expected_urls,
      found: Enum.uniq(found)
    }
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

  # The guard rails (timeouts, no retry, no redirect, `decode_body: false`, the
  # capped collector, the installation's User-Agent) come from `Http` — they are
  # the same rails every outbound fetch runs on, and this module used to keep
  # its own copy of them.
  defp request(url, req_options, max_bytes, accept) do
    options =
      url
      |> Http.base_options(max_bytes, accept)
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

  # One short, printable line out of whatever a third party served us. It goes
  # straight into a page the member reads, so it is cut to a length that cannot
  # take the layout over and stripped of the control characters an HTML escape
  # would leave as invisible junk.
  defp excerpt(value) do
    value
    |> to_string()
    |> String.replace(~r/[[:cntrl:]]+/u, " ")
    |> String.trim()
    |> String.slice(0, @max_excerpt)
  end
end
