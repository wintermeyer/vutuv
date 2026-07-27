defmodule Vutuv.Fediverse.RemoteFollow do
  @moduledoc """
  "Follow from your own server" — the one thing a visitor from another network
  wants on a member's profile.

  Handing out `@member@vutuv.de` only gets someone halfway: they still have to
  switch to their own app, paste the handle into a search box and wait for it to
  resolve. The Fediverse's answer to that is the **remote-follow (OStatus
  subscribe) template**: every server publishes, in its own WebFinger document,
  a URL template for its "you are about to follow someone" dialog. So the
  visitor tells us *their* address, we look up *their* server's template and
  send them there with our member already filled in. One click, and the follow
  is confirmed where their account actually lives — no credentials ever touch
  vutuv.

      GET https://their.server/.well-known/webfinger?resource=acct:them@their.server
      -> links: [{"rel": "http://ostatus.org/spec/1.0#subscribe",
                  "template": "https://their.server/authorize_interaction?uri={uri}"}]

  The `{uri}` is filled with the member's `acct:` URI, which their server then
  resolves against our own WebFinger endpoint.

  This is the only outbound fetch in vutuv that an **anonymous visitor** can
  trigger, so it is fenced accordingly, in the same shape
  `Vutuv.Fediverse.fetch_remote_actor/2` uses for the (equally hostile) inbox
  path: https only, the host vetted against `Vutuv.Ssrf` before the request and
  again after the single redirect hop that is allowed, short timeouts, a hard
  body ceiling that halts the stream rather than buffering, and no retries. The
  caller adds the rate limit and the `:fediverse_enabled` gate.

  Since issue #1160 the same client answers the **other** direction too:
  `resolve_actor/1` turns a pasted address into the remote account's actor URL
  (the WebFinger `self` link), which is the first step of a member here
  following somebody out there. It is the same document, the same fence and the
  same parser — only a different link is read out of it — so the two directions
  cannot drift apart on what counts as a valid address.
  """

  alias Vutuv.SocialFeed.Http
  alias Vutuv.Ssrf

  # A WebFinger document is a handful of links; anything larger is not one.
  @max_body_bytes 60_000

  # The rel an ActivityPub server publishes its follow dialog under. The OStatus
  # URI is historical: Mastodon, Pleroma, Misskey and friends all kept it when
  # they moved to ActivityPub, so it is the one portable way in. Both spellings
  # are in the wild — `schema/1.0/subscribe` is what Mastodon actually serves
  # (verified against mastodon.social), the `spec/1.0#subscribe` form appears in
  # older OStatus documents and some implementations copied it.
  @subscribe_rels [
    "http://ostatus.org/schema/1.0/subscribe",
    "http://ostatus.org/spec/1.0#subscribe"
  ]

  # What a WebFinger `self` link's media type looks like when it names the
  # ActivityPub actor document (issue #1160). Matched by prefix — see
  # `self_link?/1`.
  @actor_media_types ["application/activity+json", "application/ld+json"]

  @doc """
  The URL of the visitor's own follow dialog for `target_acct` (an `acct:` URI
  without the scheme, e.g. `"member@vutuv.de"`), or an error naming what went
  wrong so the profile can say something true:

    * `:invalid_address` — not a Fediverse address at all (a typo, an email)
    * `:unreachable` — their server did not answer, or not with a document
    * `:no_remote_follow` — it answered, but publishes no follow dialog
  """
  def subscribe_url(input, target_acct) when is_binary(target_acct) do
    with {:ok, {user, host}} <- parse_address(input),
         {:ok, template} <- subscribe_template(user, host) do
      {:ok, String.replace(template, "{uri}", URI.encode_www_form("acct:" <> target_acct))}
    end
  end

  @doc """
  The **actor URL** behind a pasted address (issue #1160): the `self` link of
  that account's WebFinger document, which is the id every ActivityPub server
  knows it by and the address a `Follow` is sent to.

  Deliberately always through WebFinger, even when somebody pasted what looks
  like an actor URL already: a profile URL (`https://server/@you`) is usually
  *not* the actor id, the two differ per implementation, and asking the server
  which id it wants to be known by is the only answer that is not a guess.

  Errors are the same vocabulary `subscribe_url/2` speaks, plus `:no_actor` when
  the document answers but names no ActivityPub identity (a WebFinger for a
  mailbox, a server that only speaks OStatus).
  """
  def resolve_actor(input) do
    with {:ok, {user, host}} <- parse_address(input),
         {:ok, body} <- webfinger(user, host),
         {:ok, %{"links" => links}} when is_list(links) <- Jason.decode(body),
         %{"href" => href} when is_binary(href) <-
           Enum.find(links, %{}, &(is_map(&1) and self_link?(&1))),
         %URI{scheme: "https", host: h} when is_binary(h) and h != "" <- URI.parse(href) do
      {:ok, href}
    else
      {:error, reason} -> {:error, reason}
      _no_usable_link -> {:error, :no_actor}
    end
  end

  # The `self` link, narrowed to the ActivityPub representation: a WebFinger
  # document also carries an HTML profile page under other rels, and following
  # that would point a signed Follow at a web page. The type is matched by
  # prefix, because the `ld+json` form legitimately carries a
  # `; profile="…/activitystreams"` parameter; a self link with no type at all
  # is accepted, since the document it names still has to survive
  # `Vutuv.Fediverse.fetch_remote_actor/2`, which demands an `id` and an `inbox`.
  defp self_link?(%{"rel" => "self"} = link) do
    case link["type"] do
      nil -> true
      type when is_binary(type) -> String.starts_with?(type, @actor_media_types)
      _other -> false
    end
  end

  defp self_link?(_link), do: false

  @doc """
  The `{user, host}` of a Fediverse address, accepting every form people paste:
  `@you@server`, `you@server`, or the profile URL `https://server/@you`.

  Pure string work — no network, no DNS — so it is safe to call anywhere.
  """
  def parse_address(input) when is_binary(input) do
    input |> String.trim() |> split_address()
  end

  def parse_address(_), do: {:error, :invalid_address}

  @doc """
  A remote account URI written the way people read it (`@you@server`), falling
  back to the URI itself when it does not name a handle. Used where a stored
  actor URI is shown to a human (the profile's forwarding address after a
  member moved their Fediverse account away).
  """
  def display_address(uri) when is_binary(uri) do
    case parse_address(uri) do
      {:ok, {user, host}} -> "@#{user}@#{host}"
      _ -> uri
    end
  end

  defp split_address("https://" <> _ = url), do: url_address(url)
  defp split_address("http://" <> _ = url), do: url_address(url)

  defp split_address(handle) do
    case handle |> String.trim_leading("@") |> String.split("@") do
      [user, host] -> validated(user, host)
      _ -> {:error, :invalid_address}
    end
  end

  # A pasted profile URL: https://server/@you (Mastodon), /users/you (the actor
  # URL some servers show). Anything else has no handle to read.
  defp url_address(url) do
    case URI.parse(url) do
      %URI{host: host, path: path} when is_binary(host) and is_binary(path) ->
        case String.split(path, "/", trim: true) do
          [user] -> validated(String.trim_leading(user, "@"), host)
          ["users", user] -> validated(user, host)
          _ -> {:error, :invalid_address}
        end

      _ ->
        {:error, :invalid_address}
    end
  end

  # The shapes a WebFinger `acct:` can have. The host must look like a real
  # domain (a dot, no port, no path), the local part like a handle — this is the
  # only thing standing between a typo and an outbound request.
  defp validated(user, host) do
    user = String.trim(user)
    host = host |> String.trim() |> String.downcase() |> String.trim_trailing(".")

    if user =~ ~r/\A[a-zA-Z0-9_.\-]{1,64}\z/ and host =~ ~r/\A[a-z0-9.\-]+\.[a-z]{2,}\z/ do
      {:ok, {user, host}}
    else
      {:error, :invalid_address}
    end
  end

  defp subscribe_template(user, host) do
    with {:ok, body} <- webfinger(user, host),
         {:ok, %{"links" => links}} when is_list(links) <- Jason.decode(body),
         %{"template" => template} when is_binary(template) <-
           Enum.find(links, %{}, &(is_map(&1) and &1["rel"] in @subscribe_rels)),
         {:ok, template} <- valid_template(template) do
      {:ok, template}
    else
      {:error, reason} -> {:error, reason}
      _no_usable_link -> {:error, :no_remote_follow}
    end
  end

  # The template is handed to the visitor's browser, so it must be a real https
  # URL with the placeholder still in it; a non-https or placeholder-less
  # "template" would send them somewhere we cannot vouch for.
  defp valid_template(template) do
    case URI.parse(template) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        if String.contains?(template, "{uri}"),
          do: {:ok, template},
          else: {:error, :no_remote_follow}

      _ ->
        {:error, :no_remote_follow}
    end
  end

  defp webfinger(user, host) do
    url =
      "https://#{host}/.well-known/webfinger?resource=" <>
        URI.encode_www_form("acct:#{user}@#{host}")

    fetch(url, 1)
  end

  # One redirect hop is followed by hand (apex -> the server's real host is a
  # common WebFinger setup) so the new host is SSRF-vetted like the first;
  # Req's own redirect following would skip that check.
  defp fetch(_url, hops) when hops < 0, do: {:error, :unreachable}

  defp fetch(url, hops) do
    with {:parse, %URI{scheme: "https", host: host}} when is_binary(host) <-
           {:parse, URI.parse(url)},
         {:ssrf, false} <- {:ssrf, Ssrf.resolves_to_internal?(host)},
         {:ok, %Req.Response{} = resp} <- Req.get(options(url)) do
      handle_response(resp, hops)
    else
      _ -> {:error, :unreachable}
    end
  end

  defp handle_response(%Req.Response{status: 200, body: body}, _hops) when is_binary(body) do
    {:ok, binary_slice(body, 0, @max_body_bytes)}
  end

  defp handle_response(%Req.Response{status: status} = resp, hops)
       when status in [301, 302, 303, 307, 308] do
    case Req.Response.get_header(resp, "location") do
      [location | _] -> fetch(location, hops - 1)
      _ -> {:error, :unreachable}
    end
  end

  defp handle_response(_resp, _hops), do: {:error, :unreachable}

  defp options(url) do
    Keyword.merge(
      [
        url: url,
        headers: [
          {"accept", "application/jrd+json, application/json"},
          {"user-agent", Http.user_agent()}
        ],
        receive_timeout: 5_000,
        connect_options: [timeout: 2_000],
        retry: false,
        redirect: false,
        # Keep the body a raw binary: we decode it ourselves after the size
        # ceiling, and Req's own JSON step would hand back a map (which the
        # cap has already stopped bounding).
        decode_body: false,
        into: Vutuv.Http.capped_collector(@max_body_bytes)
      ],
      Application.get_env(:vutuv, :fediverse_req_options, [])
    )
  end
end
