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

  alias Vutuv.Ssrf

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

  The answer comes from `Vutuv.Ssrf.internal_ip?/1`, which owns "is this address
  internal" for the whole app and matches on the parsed tuple. This used to
  stringify the address and prefix-match it, and the two disagreed on exactly
  the case that matters here: on a dual-stack listener a loopback proxy hop
  arrives IPv4-mapped, `:inet.ntoa/1` renders it `"::ffff:127.0.0.1"`, and none
  of the prefixes matched — so the dashboard reported the reverse proxy *was*
  forwarding the real client address when it was not, which is the one thing
  this predicate exists to warn about (issues #799, #837).
  """
  def private_or_loopback?(nil), do: false

  def private_or_loopback?(ip) when is_tuple(ip), do: Ssrf.internal_ip?(ip)

  def private_or_loopback?(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, parsed} -> Ssrf.internal_ip?(parsed)
      {:error, _reason} -> false
    end
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

  @doc """
  Coordinates for a zip *or* city `term` in `country` (zip tried first), or
  `nil`. The board's "near" filter resolves one input to a point through this.
  """
  defdelegate resolve_point(country, term), to: Vutuv.Geo.Postal

  @doc "Great-circle distance in km between two `{lat, lon}` points (decimal degrees)."
  defdelegate distance_km(lat1, lon1, lat2, lon2), to: Vutuv.Geo.Postal
end
