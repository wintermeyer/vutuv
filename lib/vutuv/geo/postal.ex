defmodule Vutuv.Geo.Postal do
  @moduledoc """
  Offline postal-code → geographic-coordinate resolver.

  Backed by a bundled [GeoNames](https://www.geonames.org/) postal-code dataset
  (CC BY 4.0), one standard tab-separated file per country under
  `priv/geo/<CC>.txt` or `priv/geo/<CC>.txt.gz` (gzip is read transparently).
  vutuv ships `DE`, `AT` and `CH`; another installation adds a country by
  dropping its GeoNames `zip` export (`export/zip/<CC>.zip` → `<CC>.txt`) into
  `priv/geo/` and listing the code in `:geo_countries` — see `docs/ADMINS.md`.

  Everything here is **fully offline**: no outbound call, no network flag, so it
  is safe on an air-gapped intranet installation. The dataset is parsed once, on
  first use, into a `:persistent_term` index and never reloaded (the files are
  immutable). Only the configured `:geo_countries` are loaded, so a smaller
  install pays for only what it uses, and a test run that never resolves a zip
  pays nothing at all.

  Coordinates are used at save time to stamp a job posting's `lat`/`lon` (and,
  later, to power the board's radius filter). An unknown zip resolves to `nil`
  and the posting still publishes — coordinates are an optimisation, never a
  gate.
  """

  require Logger

  @pt_key {__MODULE__, :index}

  # GeoNames postal export columns (tab-separated), 0-indexed:
  # 0 country · 1 postal · 2 place · 3-8 admin names/codes · 9 lat · 10 lon · 11 accuracy
  @col_country 0
  @col_postal 1
  @col_place 2
  @col_lat 9
  @col_lon 10

  @doc """
  Coordinates `{lat, lon}` for `zip` in `country` (ISO 3166-1 alpha-2), or `nil`
  when the country is not bundled or the postal code is unknown.
  """
  @spec coordinates(String.t(), String.t()) :: {float(), float()} | nil
  def coordinates(country, zip) when is_binary(country) and is_binary(zip) do
    Map.get(index().postal, {normalize_country(country), normalize_zip(zip)})
  end

  def coordinates(_country, _zip), do: nil

  @doc """
  Coordinates `{lat, lon}` for a place (city) name in `country`, or `nil`. A
  coarse centroid — the first entry seen for that name — good enough to anchor a
  "near <city>" search when a zip is not given.
  """
  @spec place_coordinates(String.t(), String.t()) :: {float(), float()} | nil
  def place_coordinates(country, place) when is_binary(country) and is_binary(place) do
    Map.get(index().places, {normalize_country(country), fold_place(place)})
  end

  def place_coordinates(_country, _place), do: nil

  # --- loading -------------------------------------------------------------

  defp index do
    case :persistent_term.get(@pt_key, nil) do
      nil ->
        loaded = load()
        :persistent_term.put(@pt_key, loaded)
        loaded

      loaded ->
        loaded
    end
  end

  defp load do
    Vutuv.Geo.geo_countries()
    |> Enum.reduce(%{postal: %{}, places: %{}}, fn country, acc ->
      case read_country(country) do
        {:ok, rows} -> merge_rows(acc, rows)
        :error -> acc
      end
    end)
  end

  defp merge_rows(acc, rows) do
    Enum.reduce(rows, acc, fn {postal_key, place_key, coord}, %{postal: p, places: pl} ->
      # First entry wins for a given key — the file is grouped, so this is the
      # dataset's own canonical row for that postal code / place.
      %{
        postal: Map.put_new(p, postal_key, coord),
        places: Map.put_new(pl, place_key, coord)
      }
    end)
  end

  defp read_country(country) do
    country = normalize_country(country)

    case data_path(country) do
      nil ->
        Logger.warning("Vutuv.Geo: no postal dataset for #{country} in priv/geo")
        :error

      path ->
        {:ok, path |> read_file() |> parse(country)}
    end
  end

  # Prefer an uncompressed drop-in, fall back to the shipped gzip.
  defp data_path(country) do
    dir = Application.app_dir(:vutuv, "priv/geo")

    Enum.find_value([{"#{country}.txt", :plain}, {"#{country}.txt.gz", :gzip}], fn {name, _} ->
      path = Path.join(dir, name)
      if File.exists?(path), do: path
    end)
  end

  defp read_file(path) do
    data = File.read!(path)
    if String.ends_with?(path, ".gz"), do: :zlib.gunzip(data), else: data
  end

  defp parse(data, country) do
    data
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_line(&1, country))
  end

  defp parse_line(line, country) do
    cols = String.split(line, "\t")

    with postal when is_binary(postal) <- Enum.at(cols, @col_postal),
         place when is_binary(place) <- Enum.at(cols, @col_place),
         {lat, _} <- Float.parse(Enum.at(cols, @col_lat, "")),
         {lon, _} <- Float.parse(Enum.at(cols, @col_lon, "")),
         # Guard against a stray file whose rows are for another country.
         ^country <- normalize_country(Enum.at(cols, @col_country, country)) do
      [{{country, normalize_zip(postal)}, {country, fold_place(place)}, {lat, lon}}]
    else
      _ -> []
    end
  end

  defp normalize_country(country), do: country |> String.trim() |> String.upcase()

  defp normalize_zip(zip), do: zip |> String.replace(~r/\s+/, "") |> String.upcase()

  defp fold_place(place), do: place |> String.trim() |> String.downcase()
end
