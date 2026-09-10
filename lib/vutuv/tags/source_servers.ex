defmodule Vutuv.Tags.SourceServers do
  @moduledoc """
  What the "Where should this tag come from?" panel offers, and what it is
  allowed to accept (issue #2128).

  A followed tag has carried its sources since #2125 and has been pulling from
  them since #2126, with nothing anywhere saying so. This module is the layer
  between that table and the member: the list of servers to offer, the cap on
  how many one follow may name, the cached size of each, and the one gate an
  address has to pass.

  ## The list is configuration, not code

  `:tag_source_servers` ships the vutuv.de list and `TAG_SOURCE_SERVERS`
  replaces it. **The empty list is a real setting**: an installation on an
  intranet reaches none of the shipped ten, offers nothing, and leaves every
  followed tag reading from here alone — which is what the whole feature costs
  such an installation. The master switch is the pull's own flag,
  `Vutuv.Tags.ExternalPosts.enabled?/0`: off, nothing is offered and nothing is
  asked, because a server this installation may not fetch from is not a server
  it can honestly offer.

  ## The cap

  `:tag_sources_per_follow` bounds the **other** servers one follow may name;
  this installation is always on and never counts against it. It is enforced in
  `Vutuv.Tags.add_tag_follow_source/2` rather than here, so a second writer
  cannot get past it, and it is a per-member fairness limit rather than a
  ceiling on the installation's outbound rate — that is
  `EXTERNAL_TAG_FETCH_BUDGET`.

  ## What an address has to pass

  `check/2` is the gate, and it is the same one whether the member typed the
  address or pressed a server the panel offered, so "checked before it joins the
  list" is one code path rather than a promise made twice:

    1. `https`, never `http` — we only ever fetch over TLS, and silently
       upgrading what somebody typed hides that from them,
    2. it has to be a server name and not an internal address
       (`Vutuv.Tags.TagFollowSource.normalize_source/1` and `refusal/1`, asked
       here so a value that was never a hostname costs a stranger's server no
       request at all),
    3. not this installation, which is already on and cannot be off,
    4. and it has to answer, which is `Vutuv.Tags.SourceServerProbe`'s business:
       the flag, the operator's blocklist, the SSRF vet with the connection
       pinned, and the tag timeline itself. A server that serves the timeline
       only to somebody logged in comes back `{:error, {:account_required, host}}`
       and cannot be picked yet.

  What differs between the two entry points is only whether the answer is asked
  for again: a server checked inside the freshness window is taken from the
  stored row, while everything ahead of the probe is re-decided every time,
  because those are exactly the parts that change without anybody asking.

  ## Freshness

  Every answer is stored (`Vutuv.Tags.SourceServer`) and re-asked once a day.
  Refreshing spawns one task per stale server, so a caller must be able to lend
  it a database connection — in tests that means `async: false`.
  """

  import Ecto.Query

  alias Vutuv.Fediverse
  alias Vutuv.Repo
  alias Vutuv.Tags
  alias Vutuv.Tags.SourceServer
  alias Vutuv.Tags.SourceServerProbe
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.TagFollowSource

  # How many servers may be asked at once. Well inside `Http.pinned_slot_names/0`
  # (sixteen), because the fetcher's sweeper borrows from the same fixed set and
  # a panel opening must not be able to starve it.
  @probe_concurrency 3

  # The hashtag a probe asks for when the tag it was opened from has none — a
  # punctuation-only legacy name reduces to nothing. Any hashtag answers the
  # question, because a server refuses the *endpoint*, not the topic. (The
  # fetcher refuses such a tag outright instead, and rightly: it has a timeline
  # to file, this has only a yes or no to get.)
  @fallback_hashtag "vutuv"

  @doc "Whether this installation asks other servers for anything at all."
  defdelegate enabled?(), to: SourceServerProbe

  @doc """
  The servers to offer, in configured order: normalized, deduplicated, and with
  anything the operator blocks — or this installation's own address — taken out.

  Empty when the feature is switched off, because a server we may not fetch from
  is not one to offer.
  """
  def offered, do: offered(blocked_hosts(configured()))

  defp offered(blocked) do
    if enabled?() do
      configured() |> Enum.reject(&MapSet.member?(blocked, &1)) |> Enum.uniq()
    else
      []
    end
  end

  # Normalized here rather than at every reader: what an operator writes into
  # `TAG_SOURCE_SERVERS` goes through the same door a member's typed address
  # does, so `www.` and a pasted URL fold the same way on both sides.
  defp configured do
    Application.get_env(:vutuv, :tag_source_servers, [])
    |> Enum.map(&TagFollowSource.normalize_source/1)
    |> Enum.reject(&(is_nil(&1) or &1 == Tags.local_tag_follow_source()))
  end

  defp blocked_hosts([]), do: MapSet.new()
  defp blocked_hosts(hosts), do: Fediverse.blocked_hosts(hosts)

  @doc "How many other servers one followed tag may name — see the moduledoc."
  def limit, do: Application.get_env(:vutuv, :tag_sources_per_follow, 3)

  @doc """
  The rows the panel draws for one follow: this installation first, then the
  servers this follow already names, then the ones on offer it does not.

  Each row is `%{host:, local?:, picked?:, blocked?:, info:}`, with `info` the
  stored `%SourceServer{}` or `nil` for a server nobody has asked yet. A server
  the operator blocked after somebody picked it is still shown — it is on their
  follow, and hiding it would leave them a source they cannot see to remove.
  """
  def rows(sources) when is_list(sources) do
    local = Tags.local_tag_follow_source()
    picked = Enum.reject(sources, &(&1 == local))

    # One blocklist query for both jobs: dropping a blocked server from the
    # offers, and marking a blocked one the member already picked.
    blocked = blocked_hosts(Enum.uniq(picked ++ configured()))
    hosts = Enum.uniq(picked ++ offered(blocked))
    infos = infos(hosts)

    [%{host: local, local?: true, picked?: true, blocked?: false, info: nil}] ++
      Enum.map(hosts, fn host ->
        %{
          host: host,
          local?: false,
          picked?: host in picked,
          blocked?: MapSet.member?(blocked, host),
          info: Map.get(infos, host)
        }
      end)
  end

  @doc "What is stored about each of `hosts`, keyed by host."
  def infos([]), do: %{}

  def infos(hosts) when is_list(hosts) do
    from(i in SourceServer, where: i.host in ^hosts)
    |> Repo.all()
    |> Map.new(&{&1.host, &1})
  end

  @doc """
  Asks each of `hosts` and stores what comes back, answering the same map
  `infos/1` would.

  The caller decides which hosts are stale — the panel holds the rows already
  and would otherwise make this re-read them to find out. Nothing is asked at
  all when the feature is off.
  """
  def refresh(hosts, %Tag{} = tag) when is_list(hosts) do
    if enabled?() do
      hashtag = hashtag(tag)

      hosts
      |> Task.async_stream(&probe_and_store(&1, hashtag),
        max_concurrency: @probe_concurrency,
        timeout: :infinity
      )
      |> Enum.reduce(%{}, fn
        {:ok, %SourceServer{} = info}, acc -> Map.put(acc, info.host, info)
        _other, acc -> acc
      end)
    else
      %{}
    end
  end

  defp probe_and_store(host, hashtag) do
    case SourceServerProbe.probe(host, hashtag) do
      {:ok, attrs} -> store(attrs, Repo.get_by(SourceServer, host: host))
      {:error, _reason} -> :error
    end
  end

  defp store(attrs, known) do
    case (known || %SourceServer{}) |> SourceServer.changeset(attrs) |> Repo.insert_or_update() do
      {:ok, info} -> info
      {:error, _changeset} -> :error
    end
  end

  @doc "Whether a stored answer is still worth showing without asking again."
  def fresh?(%SourceServer{checked_at: %DateTime{} = at}) do
    DateTime.diff(DateTime.utc_now(), at) < max_age()
  end

  def fresh?(_info), do: false

  # An operator writes hours; the reader wants seconds. One conversion, here.
  defp max_age, do: Application.get_env(:vutuv, :tag_server_info_max_age_hours, 24) * 3600

  @doc """
  Checks one address and answers the host to store, or why not.

  See the moduledoc for the four refusals. `{:ok, host}` means the address
  answered a public tag timeline, and its size is stored. Every refusal that
  reads better with the address in it carries it — `{:error, {reason, host}}` —
  in the spelling it would be stored under, so a caller showing the member a
  message never has to normalize it a second time to guess.
  """
  def check(typed, %Tag{} = tag) do
    with :ok <- refuse_insecure(typed),
         {:ok, host} <- server_name(typed),
         {:ok, info} <- probe(host, tag) do
      pickable(info)
    end
  end

  # `https` only, and said rather than silently corrected: a member who pasted
  # `http://` chose an address we will never fetch, and quietly upgrading it
  # would teach them this installation reads plain HTTP.
  defp refuse_insecure(typed) do
    value = typed |> to_string() |> String.trim() |> String.downcase()

    cond do
      not String.contains?(value, "://") -> :ok
      String.starts_with?(value, "https://") -> :ok
      true -> {:error, :insecure}
    end
  end

  # The literal half of the guard, asked before any request: a value that was
  # never a hostname must not cost a stranger's server a probe, and must not be
  # answered "did not answer".
  defp server_name(typed) do
    case TagFollowSource.normalize_source(typed) do
      nil ->
        {:error, {:not_a_server, to_string(typed)}}

      host ->
        cond do
          host == Tags.local_tag_follow_source() -> {:error, :local}
          reason = TagFollowSource.refusal(host) -> {:error, {reason, host}}
          true -> {:ok, host}
        end
    end
  end

  defp probe(host, tag) do
    known = Repo.get_by(SourceServer, host: host)

    if fresh?(known) do
      {:ok, known}
    else
      case SourceServerProbe.probe(host, hashtag(tag)) do
        {:ok, attrs} -> wrap(store(attrs, known), host)
        # `:disabled` is about this installation, not about that server, so it
        # is the one refusal that does not name one.
        {:error, :disabled} -> {:error, :disabled}
        {:error, reason} -> {:error, {reason, host}}
      end
    end
  end

  defp wrap(%SourceServer{} = info, _host), do: {:ok, info}
  defp wrap(:error, host), do: {:error, {:unreachable, host}}

  defp pickable(%SourceServer{host: host} = info) do
    cond do
      SourceServer.pickable?(info) -> {:ok, host}
      info.status == "account_required" -> {:error, {:account_required, host}}
      true -> {:error, {:unreachable, host}}
    end
  end

  defp hashtag(%Tag{} = tag), do: Tag.hashtag_name(tag.name || tag.slug) || @fallback_hashtag
end
