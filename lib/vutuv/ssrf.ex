defmodule Vutuv.Ssrf do
  @moduledoc """
  The one home for SSRF target detection, shared by every place that takes a
  user-supplied URL and either stores it for a later server-side fetch or
  fetches it: the profile-link screenshot validator (`Vutuv.ChangesetHelpers`),
  the webhook subscription validator (`Vutuv.Webhooks.Subscription`), and the
  two fetchers (`Vutuv.Webhooks` delivery, `Vutuv.PageScreenshot`).

  Two layers, because a changeset must never touch the network:

    * `internal_host?/1` — literal only, no DNS. Rejects `localhost` and IP
      literals in loopback / private / link-local / unique-local ranges and the
      cloud metadata address `169.254.169.254`. Cheap and deterministic, so it
      runs inside changesets (issues #773-style validators).
    * `resolves_to_internal?/1` — resolves the host (A + AAAA) and returns true
      if it is a literal internal host **or** any resolved address is internal.
      Run at fetch time to defeat DNS rebinding (a public hostname whose record
      points at an internal IP), which the literal check cannot catch (issues
      #775 / #777). There is still a TOCTOU residual (the resolver could answer
      differently between this check and the fetcher's own lookup); closing it
      fully needs connect-time peer-address validation.

  The resolver is injectable via `config :vutuv, :ssrf_resolver` (a
  `fun(charlist, :inet | :inet6) -> {:ok, [ip]} | {:error, term}`) so tests can
  drive resolution deterministically without real DNS; it defaults to
  `:inet.getaddrs/2`.
  """

  @doc """
  Whether `host` is a literal internal target: `localhost`, or an IP literal in
  a loopback / private / link-local / unique-local range (incl. the cloud
  metadata address). No DNS, so it is safe inside a changeset. A non-binary
  (e.g. a URL with no host) is not a target.
  """
  def internal_host?(host) when is_binary(host) do
    case bare_host(host) do
      bare when bare in ~w(localhost ip6-localhost ip6-loopback) ->
        true

      bare ->
        case :inet.parse_address(to_charlist(bare)) do
          {:ok, addr} -> internal_ip?(addr)
          _ -> false
        end
    end
  end

  def internal_host?(_), do: false

  @doc """
  Whether `host` is an SSRF target once DNS is taken into account: a literal
  internal host (`internal_host?/1`), or a hostname that resolves to any
  internal address. A public IP literal resolves to itself, so it is vetted by
  the literal check alone (no lookup). Resolution that finds no address is
  treated as not-internal — there is nothing to fetch, so the fetcher fails
  naturally; only a *positively* internal resolved address blocks. Use at fetch
  time, never in a changeset.
  """
  def resolves_to_internal?(host) when is_binary(host) do
    bare = bare_host(host)

    cond do
      internal_host?(host) -> true
      literal_ip?(bare) -> false
      true -> Enum.any?(resolved_addresses(bare), &internal_ip?/1)
    end
  end

  def resolves_to_internal?(_), do: true

  defp bare_host(host), do: host |> String.trim_leading("[") |> String.trim_trailing("]")

  defp literal_ip?(bare), do: match?({:ok, _}, :inet.parse_address(to_charlist(bare)))

  defp resolved_addresses(bare) do
    charlist = to_charlist(bare)
    getaddrs(charlist, :inet) ++ getaddrs(charlist, :inet6)
  end

  defp getaddrs(charlist, family) do
    resolver = Application.get_env(:vutuv, :ssrf_resolver, &:inet.getaddrs/2)

    case resolver.(charlist, family) do
      {:ok, addrs} -> addrs
      {:error, _} -> []
    end
  end

  @doc false
  def internal_ip?({0, _, _, _}), do: true
  def internal_ip?({10, _, _, _}), do: true
  def internal_ip?({127, _, _, _}), do: true
  def internal_ip?({169, 254, _, _}), do: true
  def internal_ip?({192, 168, _, _}), do: true
  def internal_ip?({172, b, _, _}) when b in 16..31, do: true
  def internal_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  def internal_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  # IPv4-mapped IPv6 (::ffff:a.b.c.d): re-check the embedded v4 address.
  def internal_ip?({0, 0, 0, 0, 0, 0xFFFF, a, b}),
    do: internal_ip?({div(a, 256), rem(a, 256), div(b, 256), rem(b, 256)})

  # Unique-local fc00::/7 and link-local fe80::/10.
  def internal_ip?({n, _, _, _, _, _, _, _}) when n in 0xFC00..0xFDFF, do: true
  def internal_ip?({n, _, _, _, _, _, _, _}) when n in 0xFE80..0xFEBF, do: true
  def internal_ip?(_), do: false
end
