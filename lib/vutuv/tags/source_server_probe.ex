defmodule Vutuv.Tags.SourceServerProbe do
  @moduledoc """
  Asks one server whether it will serve a public tag timeline, and how big it is
  (issue #2128) — the outbound half of `Vutuv.Tags.SourceServer`.

  ## The timeline decides; NodeInfo only decorates

  **The tag timeline is asked first and it alone sets `status`**, because it is
  the only thing that answers the question the panel asks. A server that serves
  its timeline perfectly but publishes no NodeInfo — or answers it 500, or names
  its document oddly — is pickable, and simply shows no figures. Deciding
  pickability on NodeInfo would make the panel's gate stricter than what
  `Vutuv.Tags.ExternalTagClient` actually needs, and strict on the wrong
  document.

  **NodeInfo** is then read for the figures the panel shows
  (`usage.users.total`, `usage.users.activeMonth`, `usage.localPosts`, and the
  server's name and description in `metadata`). It is discovered rather than
  guessed: `/.well-known/nodeinfo` links to the document, whose path is the
  server's own business (ours is under `/system/`, Mastodon's is
  `/nodeinfo/2.0`).

  **NodeInfo carries no language.** Neither 2.0 nor 2.1 has such a field; the
  issue that asked for one assumed it did. Measured against mastodon.social,
  troet.cafe and social.tchncs.de, the only place a server states it is
  Mastodon's `/api/v2/instance` (`languages`), so that is a third request — and
  an optional one.

  ## The guards

  All of them sit in front of every request and all of them can change after a
  member picked a server, which is why none lives in the changeset that stored
  it:

    * **The flag.** `Vutuv.Tags.ExternalPosts.enabled?/0` off means this
      installation asks nobody anything — an intranet — so the probe answers
      `{:error, :disabled}` without touching the network.
    * **The operator's blocklist**, consulted per probe so `/admin/fediverse`
      stays authoritative when the operator edits it afterwards.
    * **The SSRF vet with the connection pinned** (`Http.get_pinned/4`): the
      literal check a changeset can afford does not resolve, so
      `metadata.google.internal` is stored and only a resolve at fetch time
      catches it.
    * **`https` and this host only** for the NodeInfo link document. The pin
      keeps the second request on the vetted address whatever the href says, so
      the danger is not being sent elsewhere; it is quietly reading somebody
      else's URL as a path on this server and calling whatever comes back its
      NodeInfo.
  """

  require Logger

  alias Vutuv.Fediverse
  alias Vutuv.NodeInfo
  alias Vutuv.SocialFeed.Http
  alias Vutuv.SocialFeed.Post
  alias Vutuv.Tags.ExternalPosts
  alias Vutuv.Tags.ExternalTagClient
  alias Vutuv.Tags.SourceServer

  # The same seam `Vutuv.Tags.ExternalTagClient` fetches through: one feature,
  # one Req stub, so a test that stands a server up stands it up once.
  @req_options :external_tag_req_options

  @doc """
  What `host` says about itself, ready for `Vutuv.Tags.SourceServer`.

  `hashtag` is the timeline actually asked for — any hashtag answers the
  question, since a server refuses the endpoint rather than the topic.

    * `{:ok, attrs}` — with `status` `"ok"`, `"account_required"` or
      `"unreachable"`. All three are answers worth storing: they stop the panel
      asking again on the next render.
    * `{:error, :disabled | :blocked | :internal | :unresolvable | :busy}` —
      nothing was learned about the remote side, so there is nothing to store.
  """
  def probe(host, hashtag) when is_binary(host) and is_binary(hashtag) do
    with :ok <- refuse_disabled(),
         :ok <- refuse_blocked(host),
         {:ok, status} <- timeline_status(host, hashtag) do
      {:ok, Map.merge(%{host: host, status: status, checked_at: now()}, decoration(host))}
    end
  rescue
    error ->
      Logger.warning("source server probe #{host} raised: #{inspect(error)}")
      {:ok, %{host: host, status: "unreachable", checked_at: now()}}
  end

  # The rescue above covers the leg that decides `status`. This one covers the
  # optional leg, and it is separate on purpose: the figures are decoration and
  # an exception in them says nothing about whether the timeline is public. With
  # one rescue over both, a stranger's odd NodeInfo document — a `rel` that is
  # an object, so `to_string/1` raises — marked a perfectly healthy server
  # "unreachable" and unpickable for a day.
  defp decoration(host) do
    figures(host)
  rescue
    error ->
      Logger.warning("source server decoration #{host} raised: #{inspect(error)}")
      %{}
  end

  @doc "Whether this installation asks other servers for anything at all."
  defdelegate enabled?(), to: ExternalPosts

  defp refuse_disabled, do: if(enabled?(), do: :ok, else: {:error, :disabled})

  defp refuse_blocked(host) do
    if Fediverse.instance_blocked?(host), do: {:error, :blocked}, else: :ok
  end

  defp now, do: DateTime.utc_now(:second)

  # The question the panel actually needs answered. A `200` is the only "yes";
  # a refusal a logged-out reader gets is told apart from a broken server,
  # because "you need an account" is a thing to say to the member and "this
  # server is not answering" is another. `{:error, …}` travels out rather than
  # becoming a status: the SSRF vet and the pinned-slot bound say nothing about
  # the remote side, so nothing should be stored about it.
  defp timeline_status(host, hashtag) do
    path = "/api/v1/timelines/tag/#{URI.encode(hashtag, &URI.char_unreserved?/1)}?limit=1"

    case request(host, path) do
      {:ok, %Req.Response{status: 200}} ->
        {:ok, "ok"}

      {:ok, %Req.Response{status: status}} ->
        {:ok, status_of(ExternalTagClient.refusal(status))}

      {:error, reason} when reason in [:internal, :unresolvable, :busy] ->
        {:error, reason}

      {:error, _other} ->
        {:ok, "unreachable"}
    end
  end

  # `:absent` (a 404) and "not a refusal at all" (a 500) are the same thing to a
  # reader: this server is not going to hand the tag over.
  defp status_of(:account_required), do: "account_required"
  defp status_of(_other), do: "unreachable"

  # Everything the panel shows beside the switch, and nothing the switch depends
  # on: a server that answers none of this is still pickable.
  defp figures(host) do
    case node_info(host) do
      %{} = document ->
        usage = map_at(document, "usage")
        users = map_at(usage, "users")
        metadata = map_at(document, "metadata")

        %{
          node_name: clamp(metadata["nodeName"], SourceServer.max_name()),
          description: clamp(metadata["nodeDescription"], SourceServer.max_description()),
          accounts: whole_number(users["total"]),
          active_month: whole_number(users["activeMonth"]),
          posts: whole_number(usage["localPosts"]),
          language: language(host)
        }

      nil ->
        %{}
    end
  end

  defp node_info(host) do
    with %{"links" => links} when is_list(links) <- fetch(host, "/.well-known/nodeinfo"),
         path when is_binary(path) <- document_path(host, links) do
      case fetch(host, path) do
        %{} = document -> document
        _other -> nil
      end
    else
      _other -> nil
    end
  end

  # The highest-versioned link, reduced to its path — and only if it is `https`
  # and names the host being probed. See the moduledoc for what that check is
  # and is not worth.
  defp document_path(host, links) do
    links
    |> Enum.filter(
      &(is_map(&1) and String.starts_with?(to_string(&1["rel"]), NodeInfo.rel_prefix()))
    )
    |> Enum.sort_by(&to_string(&1["rel"]), :desc)
    |> Enum.find_value(fn link -> same_server_path(host, to_string(link["href"])) end)
  end

  defp with_query(path, nil), do: path
  defp with_query(path, query), do: path <> "?" <> query

  defp same_server_path(host, href) do
    case URI.parse(href) do
      %URI{scheme: "https", host: found, path: path, query: query}
      when is_binary(found) and is_binary(path) and path != "" ->
        if Fediverse.same_site?(String.downcase(found), host), do: with_query(path, query)

      _other ->
        nil
    end
  end

  # Mastodon's own instance document is the only place a server states which
  # language it is run in. Optional on purpose: a server that does not serve it
  # (or is not Mastodon) keeps every other figure and shows no badge.
  defp language(host) do
    case fetch(host, "/api/v2/instance") do
      %{"languages" => [first | _rest]} -> clamp(first, SourceServer.max_language())
      _other -> nil
    end
  end

  # A decoded JSON body, or nil for every way there is not one — decoration
  # never has to tell those apart.
  defp fetch(host, path) do
    with {:ok, %Req.Response{status: 200, body: body}} <- request(host, path),
         {:ok, document} <- Http.decode(body) do
      document
    else
      _other -> nil
    end
  end

  defp request(host, path), do: Http.get_pinned(host, path, @req_options)

  defp map_at(document, key) do
    case document[key] do
      %{} = nested -> nested
      _other -> %{}
    end
  end

  # A count from a stranger, bounded by what the column takes
  # (`Post.whole_number/2`). `nil` rather than `0` for anything unreadable: a
  # missing figure is shown as missing, and "0 accounts" is a claim — the wrong
  # one.
  defp whole_number(value), do: Post.whole_number(value)

  defp clamp(value, max) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> Post.clamp_bytes(trimmed, max)
    end
  end

  defp clamp(_value, _max), do: nil
end
