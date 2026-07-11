defmodule Vutuv.Geo do
  @moduledoc """
  Best-effort, coarse IP → location lookup for the signed-in-devices list and
  the new-device security email (issues #794 / #786).

  This is a **seam**, not a geo database. Mapping an IP to a city needs a local
  dataset (preferred, e.g. MaxMind GeoLite2) or an external API; vutuv ships
  neither by default, so `locate/1` returns `nil` unless a provider is wired in
  through the `{:vutuv, Vutuv.Geo}` config (`:provider` — a `module`/`fun`/`{m,
  f}` taking the IP string and returning a coarse location string or `nil`).

  Two hard rules, both from the issues:

    * It must **never block or fail login**. Every lookup is wrapped so a slow
      or crashing provider degrades to `nil`, and the login path treats `nil`
      as "location unknown" rather than an error.
    * Loopback / private-range IPs (localhost, LAN, the reverse-proxy hop)
      resolve to `nil` — there is no public location to show.

  Until a provider is configured the "suspicious location" trigger in
  `Vutuv.Sessions` stays dormant (it needs two known locations to compare) and
  the device list simply omits the location line. That is the intended
  best-effort behaviour, not a bug.
  """

  require Logger

  @doc """
  A coarse human-readable location for `ip` (e.g. "Berlin, DE"), or `nil` when
  it cannot be determined. `ip` may be a string or an `:inet`-style tuple.
  """
  def locate(nil), do: nil

  def locate(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string() |> locate()

  def locate(ip) when is_binary(ip) do
    cond do
      ip == "" -> nil
      private_or_loopback?(ip) -> nil
      true -> safe_lookup(ip)
    end
  end

  @doc """
  Whether `ip` is a loopback or private-range address (localhost, LAN, the
  reverse-proxy hop) rather than a public client address. Accepts an `:inet`
  tuple or a string. Used both to skip pointless geo lookups and to warn the
  admin when the reverse proxy is not forwarding the real client IP, so the app
  only ever sees the loopback hop (issues #799, #837).

  Matches the common ranges without parsing every CIDR — good enough for both.
  """
  def private_or_loopback?(nil), do: false

  def private_or_loopback?(ip) when is_tuple(ip),
    do: ip |> :inet.ntoa() |> to_string() |> private_or_loopback?()

  def private_or_loopback?(ip) when is_binary(ip) do
    ip in ["127.0.0.1", "::1", "0.0.0.0"] or
      String.starts_with?(ip, ["10.", "192.168.", "169.254.", "fc", "fd", "fe80:"]) or
      String.match?(ip, ~r/^172\.(1[6-9]|2\d|3[01])\./)
  end

  defp safe_lookup(ip) do
    case Application.get_env(:vutuv, __MODULE__, [])[:provider] do
      nil -> nil
      provider -> run_provider(provider, ip)
    end
  end

  # A provider must never take the login path down with it.
  defp run_provider(provider, ip) do
    case apply_provider(provider, ip) do
      location when is_binary(location) and location != "" -> location
      _ -> nil
    end
  rescue
    error ->
      Logger.warning("geo lookup failed for #{ip}: #{inspect(error)}")
      nil
  end

  defp apply_provider(fun, ip) when is_function(fun, 1), do: fun.(ip)
  defp apply_provider({module, fun}, ip), do: apply(module, fun, [ip])
  defp apply_provider(module, ip) when is_atom(module), do: module.locate(ip)

  # --- offline postal-code geocoding (job postings, milestone 11) ----------
  #
  # A wholly separate concern from the IP lookup above: resolving a postal code
  # to coordinates from a bundled GeoNames dataset, entirely offline. Delegated
  # to `Vutuv.Geo.Postal`; exposed here so callers say `Vutuv.Geo.coordinates/2`.

  @default_geo_countries ~w(DE AT CH)
  @default_country "DE"

  @doc "The ISO 3166-1 alpha-2 country codes whose postal data is loaded."
  def geo_countries, do: Application.get_env(:vutuv, :geo_countries, @default_geo_countries)

  @doc """
  The default country (ISO 3166-1 alpha-2) used to preselect country inputs.
  """
  def default_country, do: Application.get_env(:vutuv, :default_country, @default_country)

  @doc """
  Coordinates `{lat, lon}` for `zip` in `country`, or `nil` when unresolvable.
  Offline, from the bundled GeoNames dataset — see `Vutuv.Geo.Postal`.
  """
  defdelegate coordinates(country, zip), to: Vutuv.Geo.Postal

  @doc "Coordinates `{lat, lon}` for a place name in `country`, or `nil`."
  defdelegate place_coordinates(country, place), to: Vutuv.Geo.Postal
end
