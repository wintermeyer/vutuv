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
  # allow the obvious non-dotted exceptions (localhost and IP literals).
  defp plausible_host?(nil), do: false
  defp plausible_host?(""), do: false
  defp plausible_host?("localhost"), do: true

  defp plausible_host?(host) do
    String.contains?(host, ".") or match?({:ok, _}, :inet.parse_address(to_charlist(host)))
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
