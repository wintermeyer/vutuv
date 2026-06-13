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
      Vutuv.Ssrf.internal_host?(host) -> false
      String.contains?(host, ".") -> true
      match?({:ok, _}, :inet.parse_address(to_charlist(host))) -> true
      true -> false
    end
  end

  def downcase_value(changeset) do
    update_change(changeset, :value, &String.downcase/1)
  end

  def normalize_name(string) do
    string
    |> String.normalize(:nfd)
    |> String.replace(~r/\W/u, "")
  end
end
