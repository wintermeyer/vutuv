defmodule Vutuv.BookMetadata do
  @moduledoc """
  ISBN → book facts from Open Library's keyless APIs (no auth, no account),
  in two flavours for two callers:

    * `lookup/1` — one request to the books API, the **composer's** review
      panel prefills its form from it (title, author, year); the author can
      overwrite everything.
    * `edition_details/1` — the *edition* record, which is where Open Library
      actually keeps `number_of_pages` and the publisher (the books API often
      answers without them). `Vutuv.Posts.ReviewCovers` stores those two on
      the review while it fetches the cover, since the form has no field for
      them.

  An edition with no page count of its own — an audiobook, a scan — borrows
  the count from the **other editions of the same work**: a reader asking how
  long a book is means the book, not the pressing, so the audiobook card can
  say "190 pages" and mark it as the print edition's.

  An installation with `:fetch_book_metadata` off (air-gapped intranets)
  types the fields by hand; the lookup button then never renders and nothing
  is fetched. Tests stub HTTP via `:book_metadata_req_options` (a `plug:`
  seam, like the social-feed clients).
  """

  @req_options_key :book_metadata_req_options

  # Fetched values land in varchar(255)/integer columns unvalidated by a
  # changeset, so they are capped here: a publisher name longer than this is
  # a data accident, and a five-digit page count is not a book.
  @publisher_max 255
  @pages_max 99_999

  # How many sibling editions to weigh when borrowing a page count. Fifty
  # covers even a much-reprinted classic; the median of what they report is
  # what the card shows, so one 900-page omnibus can't skew it.
  @editions_limit 50

  @doc "Whether this installation looks up book metadata at all."
  def enabled?, do: Application.get_env(:vutuv, :fetch_book_metadata, true)

  @doc """
  Looks the normalized ISBN-13 up on Open Library's books API. Returns
  `{:ok, %{title: …, creator: …, year: …}}` (each value may be nil except
  the title) or `:error` (unknown ISBN, network trouble, flag off).
  """
  def lookup(isbn) when is_binary(isbn) do
    if enabled?(), do: request(isbn), else: :error
  end

  @doc """
  The edition facts behind an ISBN: `{:ok, %{pages: …, publisher: …}}`, both
  possibly nil, or `:error` (unknown ISBN, network trouble, flag off).

  Two requests at most: the edition record, and — only when that edition
  reports no page count — the work's other editions, whose median count
  stands in for it (see the module doc).
  """
  def edition_details(isbn) when is_binary(isbn) do
    if enabled?(), do: fetch_edition(isbn), else: :error
  end

  defp request(isbn) do
    [
      url: "https://openlibrary.org/api/books",
      params: [bibkeys: "ISBN:#{isbn}", format: "json", jscmd: "data"],
      receive_timeout: 5_000,
      retry: false
    ]
    |> Keyword.merge(Application.get_env(:vutuv, @req_options_key, []))
    |> Req.get()
    |> case do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> parse(body["ISBN:#{isbn}"])
      _other -> :error
    end
  end

  defp parse(%{"title" => title} = data) when is_binary(title) and title != "" do
    {:ok,
     %{
       title: title,
       creator: authors(data["authors"]),
       year: year(data["publish_date"])
     }}
  end

  defp parse(_missing), do: :error

  defp fetch_edition(isbn) do
    case get_json("https://openlibrary.org/isbn/#{isbn}.json") do
      {:ok, %{} = edition} ->
        {:ok,
         %{
           pages: pages(edition["number_of_pages"]) || work_pages(edition["works"]),
           publisher: first_name(edition["publishers"])
         }}

      :error ->
        :error
    end
  end

  # The page count of the work's other editions (the print run behind an
  # audiobook or a scan): their median, so neither a 32-page excerpt nor a
  # collected-works volume decides it. nil when nobody reports one.
  defp work_pages([%{"key" => key} | _rest]) when is_binary(key) do
    case get_json("https://openlibrary.org#{key}/editions.json?limit=#{@editions_limit}") do
      {:ok, %{"entries" => entries}} when is_list(entries) ->
        entries
        |> Enum.map(&pages(&1["number_of_pages"]))
        |> Enum.reject(&is_nil/1)
        |> median()

      _other ->
        nil
    end
  end

  defp work_pages(_missing), do: nil

  defp median([]), do: nil

  defp median(counts) do
    sorted = Enum.sort(counts)
    Enum.at(sorted, div(length(sorted) - 1, 2))
  end

  # The background pass can afford to wait (and to try again): it runs off the
  # request path, and a lookup lost to one slow answer leaves the card
  # silently without its facts until somebody edits the post. The composer's
  # `lookup/1` above keeps its short, no-retry budget — a member is watching
  # that one.
  defp get_json(url) do
    [url: url, receive_timeout: 15_000, retry: :transient, max_retries: 1]
    |> Keyword.merge(Application.get_env(:vutuv, @req_options_key, []))
    |> Req.get()
    |> case do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> {:ok, body}
      _other -> :error
    end
  end

  defp authors(authors) when is_list(authors) do
    case authors |> Enum.map(& &1["name"]) |> Enum.reject(&(&1 in [nil, ""])) do
      [] -> nil
      names -> Enum.join(names, ", ")
    end
  end

  defp authors(_other), do: nil

  # Open Library lists an edition's publishers as plain strings (the edition
  # record) or as `%{"name" => …}` maps (the books API); the card names the
  # first one either way — co-publishers are noise at chip size.
  defp first_name(publishers) when is_list(publishers) do
    publishers
    |> Enum.map(fn
      %{"name" => name} -> name
      name when is_binary(name) -> name
      _other -> nil
    end)
    |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
    |> case do
      nil -> nil
      name -> name |> String.trim() |> String.slice(0, @publisher_max)
    end
  end

  defp first_name(_other), do: nil

  defp pages(count) when is_integer(count) and count > 0 and count <= @pages_max, do: count
  defp pages(_other), do: nil

  # publish_date is free text ("March 2009", "1998"): the year is enough.
  defp year(date) when is_binary(date) do
    with [year] <- Regex.run(~r/\b(1\d{3}|2\d{3})\b/, date, capture: :first),
         {int, ""} <- Integer.parse(year) do
      int
    else
      _ -> nil
    end
  end

  defp year(_other), do: nil
end
