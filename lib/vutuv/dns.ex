defmodule Vutuv.Dns do
  @moduledoc """
  Reading a TXT record from the **zone's own name servers** rather than from a
  caching resolver (issue #1466).

  Domain verification is the one DNS read where a cache is the enemy. A member
  starts the claim, we look, the record is not there yet, and the recursive
  resolver caches that miss for the zone's negative TTL — which the zone's SOA
  sets, commonly hours, and which the short TTL on the record they publish
  seconds later cannot shorten. From then on every "Verify now" gets the same
  cached "no" until the negative TTL runs out, however correct the record is.
  That is what #1466 reported, and it is not fixable by retrying harder.

  So: find the deepest ancestor of the name that has `NS` records, resolve those
  name servers, and put the TXT question to them directly. There is no cache in
  front of an authoritative server, so the answer is the zone's current truth.
  All of them are asked, not just the first, because a zone whose servers are
  mid-transfer answers differently depending on who you ask and the member
  should not be punished for arriving during that window.

  Two guards. Name-server addresses come out of DNS, which the domain's owner
  controls, so an address `Vutuv.Ssrf` calls internal is dropped — pointing an
  `NS` record at `127.0.0.1` or a metadata endpoint must not turn this server
  into a probe. And a name server that answers without the `aa` bit is not
  believed (see `Vutuv.Dns.InetRes.txt_at/2`).

  When no name server can be found or none of them answers at all — a
  split-horizon intranet resolver, a firewall that only allows port 53 to the
  configured resolver — the plain recursive lookup still runs, so this can only
  make verification more likely to succeed, never less.
  """

  alias Vutuv.Dns.InetRes
  alias Vutuv.Ssrf

  # Enough to cover the usual two-to-four-server zone and to survive one being
  # down, without turning one click into a dozen queries.
  @max_nameservers 4

  @doc """
  TXT records for `name` in the `[[charlist]]` shape `:inet_res.lookup/4`
  returns (one list of string chunks per record), read from the zone's
  authoritative servers where they can be reached and from the resolver
  otherwise.
  """
  def txt_records(name, backend \\ InetRes) when is_binary(name) do
    case authoritative_txt(name, backend) do
      {:ok, records} -> records
      :error -> backend.lookup(name, :txt)
    end
  end

  @doc """
  The authoritative name servers for the zone holding `name`, as
  `{address, 53}` pairs — internal addresses dropped, capped at a handful.
  Empty when the zone cannot be determined.
  """
  def nameservers(name, backend \\ InetRes) when is_binary(name) do
    name
    |> zone_candidates()
    |> Enum.find_value([], fn zone ->
      case backend.lookup(zone, :ns) do
        [] -> nil
        names -> Enum.map(names, &to_string/1)
      end
    end)
    # Streamed, so a zone that lists a dozen name servers costs the address
    # lookups for the handful actually used and not for all twelve: `Enum.take/2`
    # stops the pipeline as soon as it has enough, and reject/uniq/take are all
    # prefix-stable, so the answer is the one the eager version gave.
    |> Stream.flat_map(&addresses(&1, backend))
    |> Stream.reject(&Ssrf.internal_ip?/1)
    |> Stream.uniq()
    |> Enum.take(@max_nameservers)
    |> Enum.map(&{&1, 53})
  end

  @doc """
  The names to try for the zone cut, deepest first: the name itself, then each
  ancestor down to two labels.

  A bare TLD is never offered. Its registry servers answer a TXT query with a
  referral rather than an answer, and a referral read as "no record" would be a
  confident wrong "no" — the exact failure this module exists to remove.
  """
  def zone_candidates(name) when is_binary(name) do
    labels = name |> String.trim_trailing(".") |> String.split(".", trim: true)
    deepest_drop = max(Enum.count(labels) - 2, -1)

    Enum.map(0..deepest_drop//1, fn drop ->
      labels |> Enum.drop(drop) |> Enum.join(".")
    end)
  end

  defp authoritative_txt(name, backend) do
    case nameservers(name, backend) do
      [] -> :error
      servers -> Enum.reduce_while(servers, :error, &ask(&1, name, backend, &2))
    end
  end

  # Reduced rather than `find_value`d: a server that answers "nothing here" is
  # still an answer we trust over the cache, so an empty result has to survive
  # the rest of the round even while a later server is asked.
  defp ask(server, name, backend, answered) do
    case backend.txt_at(name, [server]) do
      {:ok, []} -> {:cont, {:ok, []}}
      {:ok, records} -> {:halt, {:ok, records}}
      {:error, _reason} -> {:cont, answered}
    end
  end

  # IPv4 first, IPv6 only where a name server offers nothing else: an install
  # without IPv6 connectivity would otherwise spend its whole query budget on
  # addresses it cannot reach.
  defp addresses(nameserver, backend) do
    case backend.lookup(nameserver, :a) do
      [] -> backend.lookup(nameserver, :aaaa)
      addresses -> addresses
    end
  end
end
