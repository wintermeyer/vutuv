defmodule Vutuv.Address do
  @moduledoc """
  Presentation helpers for a member's postal address
  (`Vutuv.Profiles.Address`).

  Mirrors `Vutuv.Phone`: pure functions that turn a stored address into the
  lines a viewer should actually see, and into deep links to the common map
  services. The HTML view (`format_address/2`) and the agent formats both
  build on the same line logic so they can never describe an address
  differently.
  """

  alias Vutuv.Profiles.Address

  @doc """
  The address as a list of display lines, ordered top to bottom.

  The country line is dropped for a German viewer (`locale == "de"`) looking at
  a German address: a German reader does not need "Deutschland" spelled out
  under a domestic address. Every other case keeps the country line, so a
  foreign address (or a non-German viewer) never loses its country.
  """
  def lines(address, locale \\ nil)

  def lines(%Address{} = address, locale) do
    body_lines(address) ++ country_lines(address, locale)
  end

  @doc """
  Deep links to the address on the major map services, as `{service, url}`
  pairs keyed `:google`, `:openstreetmap` and `:apple`.

  The geocoding query always carries the country, even when `lines/2` hides it
  for a domestic viewer, so the dropped pin still resolves to the right place.
  """
  def map_links(%Address{} = address) do
    query = address |> map_query() |> URI.encode_www_form()

    [
      google: "https://www.google.com/maps/search/?api=1&query=#{query}",
      openstreetmap: "https://www.openstreetmap.org/search?query=#{query}",
      apple: "https://maps.apple.com/?q=#{query}"
    ]
  end

  @doc "The single-line geocoding query for the address (country always included)."
  def map_query(%Address{} = address) do
    (body_lines(address) ++ present([address.country]))
    |> Enum.join(", ")
  end

  # US addresses read "City, ST ZIP"; everything else "ZIP City".
  defp body_lines(%Address{country: "United States"} = address) do
    present([address.line_1, address.line_2, us_locality(address)])
  end

  defp body_lines(%Address{} = address) do
    present([address.line_1, address.line_2, locality(address)])
  end

  defp us_locality(%Address{city: city, state: state, zip_code: zip}) do
    region = [state, zip] |> present() |> Enum.join(" ")
    [city, region] |> present() |> Enum.join(", ")
  end

  defp locality(%Address{zip_code: zip, city: city}) do
    [zip, city] |> present() |> Enum.join(" ")
  end

  defp country_lines(%Address{country: "Germany"}, "de"), do: []

  defp country_lines(%Address{country: country}, _locale) do
    present([country_name(country)])
  end

  defp country_name("Germany"), do: "Deutschland"
  defp country_name(country), do: country

  # Keeps only the non-blank entries of a list, trimming each survivor.
  defp present(list) do
    list
    |> Enum.map(&trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
end
