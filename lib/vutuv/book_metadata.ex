defmodule Vutuv.BookMetadata do
  @moduledoc """
  ISBN → title/author/year lookup for the post composer's review panel, via
  Open Library's keyless books API (one request, no auth, no account). The
  result only **prefills** the form — the author can overwrite everything,
  and an installation with `:fetch_book_metadata` off (air-gapped intranets)
  simply types the fields by hand; the lookup button then never renders.

  Tests stub HTTP via `:book_metadata_req_options` (a `plug:` seam, like the
  social-feed clients).
  """

  @req_options_key :book_metadata_req_options

  @doc "Whether this installation looks up book metadata at all."
  def enabled?, do: Application.get_env(:vutuv, :fetch_book_metadata, true)

  @doc """
  Looks the normalized ISBN-13 up on Open Library. Returns
  `{:ok, %{title: …, creator: …, year: …}}` (each value may be nil except
  the title) or `:error` (unknown ISBN, network trouble, flag off).
  """
  def lookup(isbn) when is_binary(isbn) do
    if enabled?(), do: request(isbn), else: :error
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

  defp authors(authors) when is_list(authors) do
    case authors |> Enum.map(& &1["name"]) |> Enum.reject(&(&1 in [nil, ""])) do
      [] -> nil
      names -> Enum.join(names, ", ")
    end
  end

  defp authors(_other), do: nil

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
