defmodule Vutuv.Orcid do
  @moduledoc """
  ORCID iDs (issue #2350): the persistent identifier researchers carry across
  papers, grants and institutions, listed on the profile as a social-media
  account with the provider `"ORCID"`.

  Three things live here so the schema, the verifier and the templates agree on
  them: reading an iD out of whatever a member pastes (`parse/1`), the ISO 7064
  MOD 11-2 check digit (`valid?/1`), and the public record lookup the "this
  iD is really mine" proof reads (`fetch_researcher_urls/1`).

  The lookup asks the ORCID **public API** (`pub.orcid.org`), which hands out
  the public parts of a record without a token or a registered client. That
  matters for installability: no operator has to register anything with
  ORCID for the proof to work, and the one knob is the existing
  `:verify_social_accounts` gate (intranets that must not call out switch it
  off). HTTP goes through `Vutuv.SocialFeed.Http` with the `:orcid_req_options`
  seam, so tests stub it with a `plug:` like every other remote client.
  """

  alias Vutuv.SocialFeed.Http

  @api "https://pub.orcid.org/v3.0"
  @req_options :orcid_req_options

  # The canonical, hyphenated 16-character form: three groups of four digits
  # and a last group whose check digit may be an X (the value 10).
  @format ~r/^\d{4}-\d{4}-\d{4}-\d{3}[\dX]$/

  # An iD inside a larger string, with or without the hyphens: a pasted
  # `https://orcid.org/<id>`, the `my-orcid?orcid=<id>` page, a `/print`
  # suffix. The look-arounds keep a longer run of digits from matching by its
  # first sixteen.
  @embedded ~r/(?<![\dXx])(\d{4})-?(\d{4})-?(\d{4})-?(\d{3}[\dXx])(?![\dXx])/

  @doc """
  The iD read out of whatever the member typed or pasted, in the canonical
  hyphenated form, or the trimmed input when it carries no iD (so the
  validation error names the shape instead of a blank).
  """
  def parse(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Regex.run(@embedded, trimmed) do
      [_whole, a, b, c, d] -> Enum.join([a, b, c, String.upcase(d)], "-")
      nil -> trimmed
    end
  end

  def parse(_value), do: ""

  @doc """
  Whether `value` is a well-formed iD whose ISO 7064 MOD 11-2 check digit
  matches — a typo in any digit fails here rather than linking to a stranger's
  record.
  """
  def valid?(value) when is_binary(value) do
    Regex.match?(@format, value) and check_digit(value) == String.last(value)
  end

  def valid?(_value), do: false

  # ISO 7064 MOD 11-2 over the 15 base digits, as ORCID specifies it.
  defp check_digit(value) do
    total =
      value
      |> String.replace("-", "")
      |> String.slice(0, 15)
      |> String.to_charlist()
      |> Enum.reduce(0, fn digit, acc -> rem((acc + (digit - ?0)) * 2, 11) end)

    case rem(12 - total, 11) do
      10 -> "X"
      n -> Integer.to_string(n)
    end
  end

  @doc "The canonical address of a record."
  def url(id) when is_binary(id), do: "https://orcid.org/" <> id

  @doc """
  The URLs listed under "Websites & social links" on a public record:
  `{:ok, [url]}` (possibly empty), `{:error, :gone}` for an iD that is
  malformed, unknown or deactivated, `{:error, :transient}` when the API could
  not be asked — the verifier treats only the last as "not a verdict".
  """
  def fetch_researcher_urls(id) do
    if valid?(id), do: fetch_researcher_urls_of(id), else: {:error, :gone}
  end

  defp fetch_researcher_urls_of(id) do
    case Http.get(@api <> "/" <> id <> "/researcher-urls", @req_options) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case Http.decode(body) do
          {:ok, %{"researcher-url" => entries}} when is_list(entries) -> {:ok, urls(entries)}
          _ -> {:error, :transient}
        end

      # 404: no such iD. 409: the record is deactivated or locked — ORCID's
      # own code for "exists, but will not answer", which is not a blip either.
      {:ok, %Req.Response{status: status}} when status in [404, 409] ->
        {:error, :gone}

      _other ->
        {:error, :transient}
    end
  end

  defp urls(entries) do
    for %{"url" => %{"value" => url}} <- entries, is_binary(url), do: url
  end

  # --- the works a record lists (issue #2383) ---------------------------------

  # How many works one import reads. A record with more than this is rare, and
  # the bulk endpoint takes 100 put codes per request, so this is two requests
  # plus the summary call.
  @max_works 200
  @bulk_size 100

  @doc """
  Whether importing a record's works is enabled for this installation
  (`:import_orcid_works`, env `IMPORT_ORCID_WORKS=false` for intranets that
  must not call out).
  """
  def works_enabled?, do: Application.get_env(:vutuv, :import_orcid_works, true)

  @doc """
  The works a public record lists, reduced to the publication shape:
  `{:ok, [%{put_code, title, authors, publisher, published_year,
  published_month, url, type}]}` newest first, `{:error, :gone}` for an iD
  that is malformed, unknown or deactivated, `{:error, :transient}` when the
  API could not be asked.

  ORCID groups works by identifier and lists one summary per source inside a
  group (Crossref and the member may both have added the same paper); the
  first summary is the group's preferred one and is the one read. The summary
  carries no author list, so the chosen works are fetched again through the
  bulk endpoint (100 per request), which is where the contributors are. A
  record longer than #{@max_works} works is cut there.
  """
  def fetch_works(id) do
    if valid?(id) do
      with {:ok, put_codes} <- fetch_work_put_codes(id),
           do: fetch_work_details(id, put_codes)
    else
      {:error, :gone}
    end
  end

  # A prolific record's summary listing runs well past the shared client's
  # 2 MB ceiling (859 works measured at 3.9 MB), and reading it takes longer
  # than the shared 4 s. These two calls are the member's own request on
  # their own page, so they get a roomier budget than the background feeds.
  @max_works_bytes 10_000_000

  defp works_options,
    do: [receive_timeout: 15_000, into: Vutuv.Http.capped_collector(@max_works_bytes)]

  defp fetch_work_put_codes(id) do
    case get_json(@api <> "/" <> id <> "/works") do
      {:ok, %{"group" => groups}} when is_list(groups) ->
        {:ok, groups |> Enum.flat_map(&group_put_code/1) |> Enum.take(@max_works)}

      {:ok, _other} ->
        {:error, :transient}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp group_put_code(%{"work-summary" => [%{"put-code" => put_code} | _]})
       when is_integer(put_code),
       do: [put_code]

  defp group_put_code(_group), do: []

  defp fetch_work_details(_id, []), do: {:ok, []}

  defp fetch_work_details(id, put_codes) do
    put_codes
    |> Enum.chunk_every(@bulk_size)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      url = @api <> "/" <> id <> "/works/" <> Enum.map_join(chunk, ",", &Integer.to_string/1)

      case get_json(url) do
        {:ok, %{"bulk" => bulk}} when is_list(bulk) ->
          {:cont, {:ok, acc ++ Enum.flat_map(bulk, &bulk_work/1)}}

        {:ok, _other} ->
          {:halt, {:error, :transient}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp bulk_work(%{"work" => %{} = work}), do: List.wrap(work_entry(work))
  defp bulk_work(_other), do: []

  # One full work reduced to the publication shape. A work without a title is
  # nothing the profile could show, so it is dropped.
  defp work_entry(work) do
    case get_in(work, ["title", "title", "value"]) do
      title when is_binary(title) and title != "" ->
        %{
          put_code: work["put-code"],
          title: String.trim(title),
          authors: contributors(work),
          publisher: get_in(work, ["journal-title", "value"]),
          published_year: to_int(get_in(work, ["publication-date", "year", "value"])),
          published_month: to_int(get_in(work, ["publication-date", "month", "value"])),
          url: work_url(work),
          type: work["type"]
        }

      _no_title ->
        nil
    end
  end

  # The names as the record credits them, in order, joined the way a citation
  # lists them. Contributors without a credit name are skipped.
  defp contributors(work) do
    names =
      for %{"credit-name" => %{"value" => name}} <-
            List.wrap(get_in(work, ["contributors", "contributor"])),
          is_binary(name) and String.trim(name) != "",
          do: String.trim(name)

    case names do
      [] -> nil
      names -> Enum.join(names, ", ")
    end
  end

  # The DOI as its resolver address when the work carries one, else the URL
  # the record names. A DOI beats the URL: it is the stable one.
  defp work_url(work) do
    ids = List.wrap(get_in(work, ["external-ids", "external-id"]))

    doi =
      Enum.find_value(ids, fn
        %{"external-id-type" => "doi", "external-id-value" => value} when is_binary(value) ->
          "https://doi.org/" <> String.trim(value)

        _other ->
          nil
      end)

    doi || get_in(work, ["url", "value"])
  end

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp to_int(_value), do: nil

  # `Http.decode/1` refuses anything over the shared 2 MB, so the works
  # answers decode against their own ceiling.
  defp decode_works(body) when is_binary(body) and byte_size(body) <= @max_works_bytes,
    do: Jason.decode(body)

  defp decode_works(_body), do: {:error, :too_large}

  defp get_json(url) do
    case Http.get(url, @req_options, works_options()) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case decode_works(body) do
          {:ok, decoded} -> {:ok, decoded}
          _ -> {:error, :transient}
        end

      {:ok, %Req.Response{status: status}} when status in [404, 409] ->
        {:error, :gone}

      _other ->
        {:error, :transient}
    end
  end
end
