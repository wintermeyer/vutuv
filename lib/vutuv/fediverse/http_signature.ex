defmodule Vutuv.Fediverse.HttpSignature do
  @moduledoc """
  HTTP Signatures in the form the Fediverse speaks (draft-cavage-12, RSA over
  SHA-256): the de-facto convention, not an RFC — Mastodon rejects inbox
  deliveries that lack one.

  Outbound (`signed_headers/6`): signs `(request-target)`, `host`, `date` and,
  for requests with a body, a SHA-256 `digest` of it.

  Inbound (`valid?/2`): recomputes the signing string from the request and the
  headers the sender declared, checks the digest actually matches the raw body
  (else the signature only vouches for a header, not the payload), rejects
  stale dates (replay window), and verifies the RSA signature against the
  sender's public key — which the caller fetches from the `keyId` actor
  (`key_id/1`) first.
  """

  alias Vutuv.Fediverse.Keys

  # Mastodon uses ±1h plus some slack; a generous half day tolerates bad
  # clocks without leaving a meaningful replay window for a Follow/Undo.
  @max_age_seconds 12 * 60 * 60

  @doc """
  Headers (lowercase names) for an outbound signed request: date, host,
  digest (when there is a body) and the signature itself. `opts[:date]`
  overrides the clock for tests.
  """
  def signed_headers(method, url, body, key_id, private_key_pem, opts \\ []) do
    uri = URI.parse(url)
    date = opts[:date] || http_date()

    base =
      [{"host", uri.host}, {"date", date}] ++
        if(body, do: [{"digest", "SHA-256=" <> body_digest(body)}], else: [])

    signed_names = ["(request-target)" | Enum.map(base, &elem(&1, 0))]

    signing_string =
      build_signing_string(
        signed_names,
        "(request-target): #{method} #{request_path(uri)}",
        &:proplists.get_value(&1, base)
      )

    {:ok, key} = Keys.decode_pem(private_key_pem)
    signature = :public_key.sign(signing_string, :sha256, key)

    header =
      ~s(keyId="#{key_id}",algorithm="rsa-sha256",headers="#{Enum.join(signed_names, " ")}",) <>
        ~s(signature="#{Base.encode64(signature)}")

    base ++ [{"signature", header}]
  end

  @doc """
  Verifies an inbound request (`%{method:, path:, headers:, body:}`, header
  names lowercase) against the sender's public key PEM.
  """
  def valid?(%{method: method, path: path, headers: headers, body: body}, public_key_pem) do
    with {:ok, params} <- parse(headers["signature"]),
         :ok <- check_required(params.headers, body),
         :ok <- check_digest(headers["digest"], body),
         :ok <- check_date(headers["date"]),
         {:ok, key} <- Keys.decode_pem(public_key_pem) do
      signing_string =
        build_signing_string(
          params.headers,
          "(request-target): #{method} #{path}",
          &headers[&1]
        )

      if :public_key.verify(signing_string, :sha256, params.signature, key) do
        :ok
      else
        {:error, :invalid_signature}
      end
    end
  end

  @doc "The keyId URI out of a Signature header (names the sender's actor)."
  def key_id(header) do
    case parse(header) do
      {:ok, %{key_id: key_id}} -> {:ok, key_id}
      {:error, _} = error -> error
    end
  end

  defp parse(nil), do: {:error, :no_signature}

  defp parse(header) when is_binary(header) do
    params =
      Regex.scan(~r/(\w+)="([^"]*)"/, header)
      |> Map.new(fn [_, k, v] -> {k, v} end)

    with %{"keyId" => key_id, "signature" => signature} <- params,
         {:ok, decoded} <- Base.decode64(signature) do
      names = params |> Map.get("headers", "date") |> String.downcase() |> String.split(" ")
      {:ok, %{key_id: key_id, headers: names, signature: decoded}}
    else
      :error -> {:error, :bad_signature_encoding}
      _ -> {:error, :no_key_id}
    end
  end

  # The signature must cover the target, the date (replay window) and, when
  # a body exists, its digest — otherwise a valid signature could be replayed
  # against another inbox or with another payload.
  defp check_required(names, body) do
    required = ["(request-target)", "date"] ++ if(body, do: ["digest"], else: [])

    if Enum.all?(required, &(&1 in names)) do
      :ok
    else
      {:error, :unsigned_required_header}
    end
  end

  defp check_digest(_header, nil), do: :ok
  defp check_digest(nil, _body), do: {:error, :missing_digest}

  defp check_digest(header, body) do
    case String.split(header, "=", parts: 2) do
      [algo, value] ->
        if String.downcase(algo) == "sha-256" and value == body_digest(body) do
          :ok
        else
          {:error, :digest_mismatch}
        end

      _ ->
        {:error, :digest_mismatch}
    end
  end

  defp check_date(nil), do: {:error, :missing_date}

  defp check_date(header) do
    # RFC 1123: "Tue, 01 Jul 2026 12:00:00 GMT"
    with [_wd, day, mon, year, time, "GMT"] <- String.split(header, " "),
         {:ok, date} <- parse_date(day, mon, year),
         {:ok, time} <- Time.from_iso8601(time),
         {:ok, sent} <- DateTime.new(date, time, "Etc/UTC") do
      if abs(DateTime.diff(DateTime.utc_now(), sent)) <= @max_age_seconds do
        :ok
      else
        {:error, :stale_date}
      end
    else
      _ -> {:error, :bad_date}
    end
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  defp parse_date(day, mon, year) do
    # Integer.parse/1 (not String.to_integer/1) so an attacker-controlled Date
    # header with a non-numeric day/year flows to {:error, :bad_date} instead of
    # raising an ArgumentError that 500s (and floods the log on) the AP inbox.
    with index when not is_nil(index) <- Enum.find_index(@months, &(&1 == String.capitalize(mon))),
         {y, ""} <- Integer.parse(year),
         {d, ""} <- Integer.parse(day) do
      Date.new(y, index + 1, d)
    else
      _ -> :error
    end
  end

  defp build_signing_string(names, target_line, lookup_fun) do
    Enum.map_join(names, "\n", fn
      "(request-target)" -> target_line
      name -> "#{name}: #{lookup_fun.(name)}"
    end)
  end

  defp body_digest(body), do: :sha256 |> :crypto.hash(body) |> Base.encode64()

  defp http_date, do: Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S GMT")

  defp request_path(%URI{path: path, query: nil}), do: path || "/"
  defp request_path(%URI{path: path, query: query}), do: "#{path || "/"}?#{query}"
end
