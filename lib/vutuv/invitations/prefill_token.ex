defmodule Vutuv.Invitations.PrefillToken do
  @moduledoc """
  Compact, URL-safe encoding of the sign-up prefill an inviter enters.

  The invitation link carries the invited person's gender, first/last name,
  email and tags so the landing-page sign-up form arrives prefilled (see
  `Vutuv.Invitations` and `VutuvWeb.PageController.index/2`). Spelling the fields
  out as `?first_name=…&last_name=…&email=…&tags=…` is long — the parameter names
  repeat on every link and the values are percent-encoded (`@` → `%40`, `,` →
  `%2C`, space → `+`) — and it exposes the invitee's name and address in
  **cleartext** in a URL that ends up in mail logs, browser history and referrer
  headers.

  This packs the fields into a single opaque `i=` parameter: the values in a
  fixed order joined by a separator, DEFLATE-compressed and base64url-encoded.
  For a real invite (which always has at least a name — the form requires it) the
  token is both **shorter** than the spelled-out query and no longer leaks the
  PII in the clear.

  Compressing helps only *after* packing. DEFLATE-ing the spelled-out query
  string on its own makes it **longer**: its header plus base64's ~33 % inflation
  beat what DEFLATE can win back on so little text. The saving comes from dropping
  the repeated parameter names and the percent-encoding; DEFLATE on the packed
  values then trims a further ~10–20 % on longer (e.g. German) payloads.

  The scheme is deliberately **unsigned** — the values are only form defaults the
  invited person reviews and edits before submitting, so there is nothing to
  protect, and a signature would add ~50 characters and defeat the point.

  `query/1` is the writer (used by `Vutuv.Notifications.Emailer`); `decode/1` is
  the reader (used by the landing page via `Vutuv.Invitations.prefill_from_params/1`).
  `decode/1` never raises: any malformed token yields an empty prefill (a blank
  sign-up form), the same as visiting the bare homepage. Older invitation links
  still in inboxes use the spelled-out params and keep working, since the reader
  falls back to them when there is no `i=` token.
  """

  # The value order inside the token. Changing it is a breaking change to the
  # format; bump @version and keep decoding the old layout if that ever happens.
  @fields ~w(gender first_name last_name email tags)
  @separator "\x1f"
  @version 1
  @param "i"

  @doc "The query-parameter name that carries the token (`\"i\"`)."
  def param, do: @param

  @doc """
  The query string for `prefill` — the **shorter** of the compact `i=` token and
  the spelled-out `key=value` pairs, so an invitation link is never made longer.

  Returns `""` when there is nothing to prefill.
  """
  def query(prefill) when is_map(prefill) do
    plain = plain_query(prefill)

    case encode(prefill) do
      nil ->
        plain

      token ->
        packed = @param <> "=" <> token
        if String.length(packed) <= String.length(plain), do: packed, else: plain
    end
  end

  @doc """
  Encode `prefill` (a map with string keys `gender` / `first_name` / `last_name`
  / `email` / `tags`) into a base64url token, or `nil` when every field is blank.
  """
  def encode(prefill) when is_map(prefill) do
    values = Enum.map(@fields, fn field -> to_string(Map.get(prefill, field) || "") end)

    if Enum.all?(values, &(&1 == "")) do
      nil
    else
      payload = values |> Enum.join(@separator) |> String.trim_trailing(@separator)

      (<<@version>> <> payload)
      |> deflate()
      |> Base.url_encode64(padding: false)
    end
  end

  @doc """
  Decode a token back into the prefill map (blank fields omitted). Returns `%{}`
  for anything that is not a token we produced, so a tampered or truncated link
  degrades to an empty form rather than crashing.
  """
  def decode(token) when is_binary(token) and token != "" do
    with {:ok, deflated} <- Base.url_decode64(token, padding: false),
         {:ok, <<@version, payload::binary>>} <- inflate(deflated) do
      @fields
      |> Enum.zip(String.split(payload, @separator))
      |> Enum.reject(fn {_field, value} -> value == "" end)
      |> Map.new()
    else
      _ -> %{}
    end
  end

  def decode(_), do: %{}

  # Raw DEFLATE (window bits -15 = no zlib/gzip header or trailing checksum, the
  # smallest framing) — matched by inflate/1 below.
  defp deflate(binary) do
    z = :zlib.open()

    try do
      :zlib.deflateInit(z, :best_compression, :deflated, -15, 8, :default)
      IO.iodata_to_binary(:zlib.deflate(z, binary, :finish))
    after
      :zlib.close(z)
    end
  end

  defp inflate(binary) do
    z = :zlib.open()

    try do
      :zlib.inflateInit(z, -15)
      {:ok, IO.iodata_to_binary(:zlib.inflate(z, binary))}
    catch
      _kind, _reason -> :error
    after
      :zlib.close(z)
    end
  end

  defp plain_query(prefill) do
    prefill
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Enum.sort()
    |> URI.encode_query()
  end
end
