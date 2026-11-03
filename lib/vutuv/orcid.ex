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
end
