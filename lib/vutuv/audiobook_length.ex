defmodule Vutuv.AudiobookLength do
  @moduledoc """
  ISBN → **running time of an audiobook**, read from a library catalogue's
  extent field. Open Library knows page counts but not durations, so this
  asks the Deutsche Nationalbibliothek's keyless SRU interface instead and
  parses MARC field 300 ("Umfang"), where German audiobook records carry the
  length: `Online-Ressource 75 Min.`, `1 Online-Ressource (2 CDs (ca. 136
  Min.))`, `6 CDs (ca. 7 Std. 20 Min.)`.

  Best-effort and clearly bounded: it answers only for an ISBN the catalogue
  holds *as an audiobook edition* (a print ISBN carries no duration), and
  only when the record states one — plenty of records say just "2 CDs". A
  review whose ISBN is the print edition therefore shows pages and no
  duration, which is honest.

  The DNB is a German catalogue and the natural source for a German site;
  an installation elsewhere can point `:dnb_sru_url` at another SRU endpoint
  that answers MARC21-xml, or blank it to switch the lookup off. It is
  gated by `:fetch_book_metadata` like every other book lookup, so an
  air-gapped install never calls out. Tests stub HTTP via
  `:dnb_req_options`.
  """

  alias Vutuv.BookMetadata

  require Logger

  @req_options_key :dnb_req_options

  # Longer than any audiobook and long enough to catch a mis-parse: a record
  # claiming more than this is not a running time we should print.
  @max_minutes 6_000

  @doc "Where the SRU lookup goes; nil/blank switches the feature off."
  def endpoint, do: Application.get_env(:vutuv, :dnb_sru_url, "https://services.dnb.de/sru/dnb")

  @doc """
  The audiobook's running time in whole minutes, or nil — unknown ISBN, a
  record without a stated length, network trouble, lookup off.
  """
  def minutes(isbn) when is_binary(isbn) do
    with true <- BookMetadata.enabled?(),
         url when is_binary(url) and url != "" <- endpoint(),
         {:ok, xml} <- search(url, isbn) do
      xml |> extent() |> parse_minutes()
    else
      _off_or_unavailable -> nil
    end
  rescue
    exception ->
      Logger.warning(
        "audiobook length lookup failed for #{isbn}: #{Exception.message(exception)}"
      )

      nil
  end

  defp search(url, isbn) do
    [
      url: url,
      params: [
        version: "1.1",
        operation: "searchRetrieve",
        query: "num=#{isbn}",
        recordSchema: "MARC21-xml",
        maximumRecords: 1
      ],
      receive_timeout: 8_000,
      retry: false
    ]
    |> Keyword.merge(Application.get_env(:vutuv, @req_options_key, []))
    |> Req.get()
    |> case do
      {:ok, %Req.Response{status: 200, body: xml}} when is_binary(xml) -> {:ok, xml}
      _other -> :error
    end
  end

  # MARC 300 subfield a ("1 Online-Ressource (2 CDs (ca. 136 Min.))"). One
  # field out of one record is all we want, so this reads the XML with a
  # targeted regex rather than dragging in a parser: a miss yields nil, which
  # is the same answer as "the record states no length".
  defp extent(xml) do
    with [field] <- Regex.run(~r{<(?:\w+:)?datafield[^>]*tag="300".*?</(?:\w+:)?datafield>}s, xml),
         [_match, value] <- Regex.run(~r{<(?:\w+:)?subfield[^>]*code="a">([^<]*)<}, field) do
      value
    else
      _nothing -> nil
    end
  end

  defp parse_minutes(nil), do: nil

  defp parse_minutes(extent) do
    hours = captured(extent, ~r/(\d{1,3})\s*(?:Std|Stunden|Stunde|h)\b/i)
    minutes = captured(extent, ~r/(\d{1,4})\s*(?:Min|Minuten|Minute)\b/i)

    case (hours || 0) * 60 + (minutes || 0) do
      0 -> nil
      total when total > @max_minutes -> nil
      total -> total
    end
  end

  defp captured(text, regex) do
    with [_all, digits] <- Regex.run(regex, text),
         {number, ""} <- Integer.parse(digits) do
      number
    else
      _nothing -> nil
    end
  end
end
