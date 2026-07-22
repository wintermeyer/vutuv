defmodule Vutuv.AudiobookLength do
  @moduledoc """
  The **running time of an audiobook**, read from a library catalogue's extent
  field. Open Library knows page counts but not durations, so this asks the
  Deutsche Nationalbibliothek's keyless SRU interface and parses MARC field
  300 ("Umfang"), where German audiobook records carry the length:
  `Online-Ressource 75 Min.`, `1 Online-Ressource (2 CDs (ca. 136 Min.))`,
  `6 CDs (ca. 7 Std. 20 Min.)`.

  `lookup/1` answers in two steps, and the second one is where the care sits:

    1. **By ISBN.** If the review's own ISBN is the audio edition's, the
       catalogue states that edition's length and the answer is exact.
    2. **By title + author**, when it is not — most reviews carry the print
       ISBN. The catalogue is asked for the work's *spoken-word* editions
       (RDA content type `spw`), and the answer is used **only when those
       editions agree**. They often do not: "Russendisko" has a 73-minute
       reading, an 81-minute radio play and a 125-minute sequel under nearly
       the same title; "Der Herr der Ringe" ranges from a 11-hour radio play
       to a 59-hour Komplettlesung. Guessing which recording a member
       listened to would print a wrong number as fact, so a disagreeing set
       yields **nothing**. What survives the filters — same title, spoken
       word, not a radio play, a stated length, all lengths equal — is
       returned together with the ISBN it came from, and the card marks such
       a borrowed runtime as approximate.

  The DNB is a German catalogue and the natural source for a German site; an
  installation elsewhere can point `:dnb_sru_url` at another SRU endpoint
  answering MARC21-xml, or blank it to switch the lookup off. Gated by
  `:fetch_book_metadata` like every other book lookup, so an air-gapped
  install never calls out. Tests stub HTTP via `:dnb_req_options`.
  """

  alias Vutuv.BookMetadata
  alias Vutuv.Posts.PostReview

  require Logger

  @req_options_key :dnb_req_options

  # Longer than any audiobook and long enough to catch a mis-parse: a record
  # claiming more than this is not a running time we should print.
  @max_minutes 6_000

  # How many records the title/author search weighs. A work with more
  # spoken-word editions than this is one where the set disagrees anyway.
  @search_records 40

  # A radio play is not the audiobook someone reviewed, and it is the one
  # kind of record that regularly sits alone under a book's title with a
  # length attached — so it is filtered out rather than trusted.
  @radio_play ~r/hörspiel/i

  @doc "Where the SRU lookup goes; nil/blank switches the feature off."
  def endpoint, do: Application.get_env(:vutuv, :dnb_sru_url, "https://services.dnb.de/sru/dnb")

  @doc """
  The running time of the reviewed audiobook: `{minutes, isbn_or_nil}` where
  the ISBN names the edition the time was read from (nil = the review's own
  ISBN, i.e. an exact answer), or `nil` when no length can be established
  honestly. See the module doc for what "honestly" rules out.
  """
  def lookup(%PostReview{identifier: isbn} = review) when is_binary(isbn) do
    with true <- BookMetadata.enabled?(),
         url when is_binary(url) and url != "" <- endpoint() do
      case by_isbn(url, isbn) do
        nil -> by_work(url, review)
        minutes -> {minutes, nil}
      end
    else
      _off -> nil
    end
  rescue
    exception ->
      Logger.warning(
        "audiobook length lookup failed for #{isbn}: #{Exception.message(exception)}"
      )

      nil
  end

  def lookup(%PostReview{}), do: nil

  @doc """
  The running time of the edition behind one ISBN, in whole minutes, or nil.
  The precise half of `lookup/1`, exposed for callers holding just an ISBN.
  """
  def minutes(isbn) when is_binary(isbn) do
    with true <- BookMetadata.enabled?(),
         url when is_binary(url) and url != "" <- endpoint() do
      by_isbn(url, isbn)
    else
      _off -> nil
    end
  rescue
    exception ->
      Logger.warning(
        "audiobook length lookup failed for #{isbn}: #{Exception.message(exception)}"
      )

      nil
  end

  defp by_isbn(url, isbn) do
    case search(url, "num=#{isbn}", 1) do
      {:ok, xml} -> xml |> records() |> List.first() |> record_minutes()
      :error -> nil
    end
  end

  # The work's other spoken-word editions, used only if they agree. `title`
  # and `creator` are what the member typed, so the query is deliberately
  # narrow and the results are matched against the title again.
  defp by_work(_url, %PostReview{title: title, creator: creator})
       when not is_binary(title) or not is_binary(creator),
       do: nil

  defp by_work(url, %PostReview{title: title, creator: creator}) do
    with {:ok, xml} <- search(url, "tit=#{title} and per=#{creator}", @search_records),
         [_ | _] = candidates <- audiobook_candidates(xml, title),
         [{minutes, isbn} | _] <- unanimous(candidates) do
      {minutes, isbn}
    else
      _nothing -> nil
    end
  end

  defp audiobook_candidates(xml, title) do
    wanted = normalize_title(title)

    xml
    |> records()
    |> Enum.filter(&spoken_word?/1)
    |> Enum.reject(&radio_play?/1)
    |> Enum.filter(&(normalize_title(subfield(&1, "245", "a")) == wanted))
    |> Enum.map(&{record_minutes(&1), subfield(&1, "020", "a")})
    |> Enum.reject(fn {minutes, _isbn} -> is_nil(minutes) end)
  end

  # The heart of the honesty rule: one running time, or none. Editions that
  # state the same length are the same recording as far as a card is
  # concerned; a spread means we cannot know which one was reviewed.
  defp unanimous(candidates) do
    case candidates |> Enum.map(&elem(&1, 0)) |> Enum.uniq() do
      [_single] -> candidates
      _spread_or_empty -> nil
    end
  end

  defp search(url, query, records) do
    [
      url: url,
      params: [
        version: "1.1",
        operation: "searchRetrieve",
        query: query,
        recordSchema: "MARC21-xml",
        maximumRecords: records
      ],
      # Patient and retried once, like the other background lookups: a
      # catalogue that answers slowly should cost a second, not the fact.
      receive_timeout: 15_000,
      retry: :transient,
      max_retries: 1
    ]
    |> Keyword.merge(Application.get_env(:vutuv, @req_options_key, []))
    |> Req.get()
    |> case do
      {:ok, %Req.Response{status: 200, body: xml}} when is_binary(xml) -> {:ok, xml}
      _other -> :error
    end
  end

  # One record out of an SRU answer is a handful of MARC fields, so these read
  # the XML with targeted regexes rather than dragging in a parser: a miss
  # yields nil, the same answer as "the record does not say".
  defp records(xml) do
    Regex.scan(~r{<(?:\w+:)?record\b.*?</(?:\w+:)?record>}s, xml) |> Enum.map(&hd/1)
  end

  defp record_minutes(nil), do: nil
  defp record_minutes(record), do: record |> subfield("300", "a") |> parse_minutes()

  defp subfield(record, tag, code) do
    with [field] <-
           Regex.run(~r{<(?:\w+:)?datafield[^>]*tag="#{tag}".*?</(?:\w+:)?datafield>}s, record),
         [_match, value] <- Regex.run(~r{<(?:\w+:)?subfield[^>]*code="#{code}">([^<]*)<}, field) do
      value
    else
      _nothing -> nil
    end
  end

  # RDA content type (MARC 336 subfield b): `spw` = spoken word. A print or
  # e-book record of the same title never carries it.
  defp spoken_word?(record), do: subfield(record, "336", "b") == "spw"

  defp radio_play?(record) do
    [subfield(record, "245", "a"), subfield(record, "245", "b")]
    |> Enum.any?(&(is_binary(&1) and &1 =~ @radio_play))
  end

  # Catalogue titles carry the non-sorting markers ¬…¬ around leading
  # articles ("&#152;Der&#156; Herr der Ringe") and trailing spaces; the
  # member typed neither. They also arrive **decomposed** (NFD: "Scho" +
  # combining diaeresis), while anything typed into a browser is composed —
  # so "Schönhauser Allee" from the catalogue and from the composer are
  # different binaries until both are normalized, and every title with an
  # umlaut would silently fail to match.
  defp normalize_title(nil), do: nil

  defp normalize_title(title) do
    title
    |> String.replace(~r/&#\d+;|[\x{0098}\x{009C}]/u, "")
    |> String.normalize(:nfc)
    |> String.trim()
    |> String.downcase()
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
