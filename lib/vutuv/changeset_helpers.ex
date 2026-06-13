defmodule Vutuv.ChangesetHelpers do
  @moduledoc false

  import Ecto.Changeset
  use Gettext, backend: VutuvWeb.Gettext

  def validate_url(changeset, field \\ :value) do
    url = get_change(changeset, field)

    if url do
      validate_parsed_url(changeset, field, URI.parse(url))
    else
      changeset
    end
  end

  defp validate_parsed_url(changeset, field, %URI{scheme: nil}) do
    add_error(changeset, field, gettext("Invalid URL"))
  end

  # Only http(s) links. A `javascript:`/`data:`/`vbscript:` value would reach a
  # rendered `href` on the public profile and execute on click (stored XSS);
  # the scheme check rejects it before it is ever stored.
  defp validate_parsed_url(changeset, field, %URI{scheme: scheme})
       when scheme not in ["http", "https"] do
    add_error(changeset, field, gettext("Invalid URL"))
  end

  # Syntax-only validation: a URI with a scheme and a plausibly-shaped host is
  # accepted. We deliberately do NOT resolve the host here. A DNS lookup inside
  # the changeset would block the request worker for the resolver timeout on an
  # unresolvable or blackholed host, make validation network-dependent and
  # non-deterministic, and act as a DNS-probe vector. Reachability, if wanted,
  # belongs out-of-band (e.g. the post-insert screenshot task setting `broken`).
  defp validate_parsed_url(changeset, field, %URI{host: host}) do
    if plausible_host?(host) do
      changeset
    else
      add_error(changeset, field, gettext("Invalid URL"))
    end
  end

  # A bare single-label host (e.g. "invalid_url") is rejected without touching
  # the network: a real public URL host is dotted (has a TLD), and we still
  # allow the non-dotted IP-literal exceptions. Internal targets are rejected
  # outright — a profile link is screenshotted server-side by headless
  # Chromium, so an internal host would be a readable SSRF (exfiltration via
  # the rendered thumbnail).
  defp plausible_host?(nil), do: false
  defp plausible_host?(""), do: false

  defp plausible_host?(host) do
    cond do
      internal_host?(host) -> false
      String.contains?(host, ".") -> true
      match?({:ok, _}, :inet.parse_address(to_charlist(host))) -> true
      true -> false
    end
  end

  # Hosts whose server-side fetch would hit our own network: localhost and IP
  # literals in loopback / private / link-local / unique-local ranges, incl.
  # the cloud metadata address 169.254.169.254. Literal-only (no DNS — matches
  # the no-network design above); a hostname that *resolves* to an internal IP
  # is a separate, capture-time concern.
  defp internal_host?(host) do
    bare = host |> String.trim_leading("[") |> String.trim_trailing("]")

    cond do
      bare in ~w(localhost ip6-localhost ip6-loopback) ->
        true

      match?({:ok, _}, :inet.parse_address(to_charlist(bare))) ->
        {:ok, addr} = :inet.parse_address(to_charlist(bare))
        internal_ip?(addr)

      true ->
        false
    end
  end

  defp internal_ip?({0, _, _, _}), do: true
  defp internal_ip?({10, _, _, _}), do: true
  defp internal_ip?({127, _, _, _}), do: true
  defp internal_ip?({169, 254, _, _}), do: true
  defp internal_ip?({192, 168, _, _}), do: true
  defp internal_ip?({172, b, _, _}) when b in 16..31, do: true
  defp internal_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp internal_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  # IPv4-mapped IPv6 (::ffff:a.b.c.d): re-check the embedded v4 address.
  defp internal_ip?({0, 0, 0, 0, 0, 0xFFFF, a, b}),
    do: internal_ip?({div(a, 256), rem(a, 256), div(b, 256), rem(b, 256)})

  # Unique-local fc00::/7 and link-local fe80::/10.
  defp internal_ip?({n, _, _, _, _, _, _, _}) when n in 0xFC00..0xFDFF, do: true
  defp internal_ip?({n, _, _, _, _, _, _, _}) when n in 0xFE80..0xFEBF, do: true
  defp internal_ip?(_), do: false

  def downcase_value(changeset) do
    update_change(changeset, :value, &String.downcase/1)
  end

  def normalize_name(string) do
    string
    |> String.normalize(:nfd)
    |> String.replace(~r/\W/u, "")
  end
end
