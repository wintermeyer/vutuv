defmodule Vutuv.BookMetadata do
  @moduledoc """
  ISBN → book facts from Open Library's keyless APIs (no auth, no account).

  `edition_details/1` reads the *edition* record, which is where Open Library
  keeps `number_of_pages` and the publisher. `Vutuv.Posts.ReviewCovers` stores
  those two on a review sidecar (`Vutuv.Posts.PostReview`) while it fetches the
  cover — the background pass that keeps existing review posts' cards complete.
  (The composer's review form, whose ISBN lookup used to prefill title, author
  and year from the books API, was removed 2026-07-30.)

  An edition with no page count of its own — an audiobook, a scan — borrows
  the count from the **other editions of the same work**: a reader asking how
  long a book is means the book, not the pressing, so the audiobook card can
  say "190 pages" and mark it as the print edition's.

  An installation with `:fetch_book_metadata` off (air-gapped intranets)
  fetches nothing. Tests stub HTTP via `:book_metadata_req_options` (a `plug:`
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
  The edition facts behind an ISBN: `{:ok, %{pages: …, publisher: …}}`, both
  possibly nil, or `:error` (unknown ISBN, network trouble, flag off).

  Two requests at most: the edition record, and — only when that edition
  reports no page count — the work's other editions, whose median count
  stands in for it (see the module doc).
  """
  def edition_details(isbn) when is_binary(isbn) do
    if enabled?(), do: fetch_edition(isbn), else: :error
  end

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
  # silently without its facts until somebody edits the post.
  defp get_json(url) do
    [url: url, receive_timeout: 15_000, retry: :transient, max_retries: 1]
    |> Keyword.merge(Application.get_env(:vutuv, @req_options_key, []))
    |> Req.get()
    |> case do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> {:ok, body}
      _other -> :error
    end
  end

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
end
