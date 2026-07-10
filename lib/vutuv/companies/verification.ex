defmodule Vutuv.Companies.Verification do
  @moduledoc """
  The two domain-proof methods behind verified company pages (issue #929), both
  proving control of the DOMAIN itself (never merely an address on it):

    * `dns` — a `vutuv-verify=<token>` TXT record, read with the OTP stub
      resolver (`dns_verified?/2`).
    * `well_known` — the token served at
      `https://domain/.well-known/vutuv-verify.txt`, fetched with `Req` behind
      the SSRF guard (`well_known_verified?/2`), never following redirects.

  Both are network calls, so they are gated by
  `config :vutuv, :verify_company_domains` (default on). Off = company domain
  verification is disabled on this installation (no outbound calls). The
  resolver and the `Req` options are injectable so the suite never touches real
  DNS or the network.
  """

  require Logger

  @dns_prefix "vutuv-verify="
  @well_known_path "/.well-known/vutuv-verify.txt"
  @max_well_known_bytes 4_096

  @doc "Whether the domain-proof methods are enabled for this installation."
  def enabled? do
    Application.get_env(:vutuv, :verify_company_domains, true)
  end

  @doc "A fresh unguessable verification token (~192 bits, URL-safe)."
  def gen_token do
    24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  # --- DNS TXT ----------------------------------------------------------------

  @doc "The exact TXT record value a member must publish for the `dns` method."
  def dns_txt_value(token), do: @dns_prefix <> token

  @doc "Whether `host` publishes a `vutuv-verify=<token>` TXT record."
  def dns_verified?(host, token) when is_binary(host) and is_binary(token) do
    expected = dns_txt_value(token)
    Enum.any?(txt_records(host), &(&1 == expected))
  end

  defp txt_records(host) do
    resolver = Application.get_env(:vutuv, :companies_dns_resolver, &default_txt_lookup/1)

    host
    |> resolver.()
    |> Enum.map(fn parts -> Enum.map_join(parts, "", &to_string/1) end)
  rescue
    _ -> []
  end

  # `:inet_res.lookup/3` returns each TXT record as a list of charlist chunks.
  defp default_txt_lookup(host) do
    :inet_res.lookup(to_charlist(host), :in, :txt)
  end

  # --- well-known file --------------------------------------------------------

  @doc "The URL fetched for the `well_known` method."
  def well_known_url(host), do: "https://" <> host <> @well_known_path

  @doc """
  Whether `https://host/.well-known/vutuv-verify.txt` serves exactly `token`.
  Guarded against SSRF (host must not resolve to an internal address) and never
  follows redirects.
  """
  def well_known_verified?(host, token) when is_binary(host) and is_binary(token) do
    case fetch_well_known(host) do
      {:ok, body} -> String.trim(body) == token
      {:error, _} -> false
    end
  end

  defp fetch_well_known(host) do
    if Vutuv.Ssrf.resolves_to_internal?(host) do
      {:error, :ssrf}
    else
      request(well_known_url(host))
    end
  end

  defp request(url) do
    options =
      [
        url: url,
        receive_timeout: 4_000,
        connect_options: [timeout: 2_000],
        retry: false,
        redirect: false,
        decode_body: false,
        headers: [{"user-agent", user_agent()}, {"accept", "text/plain"}]
      ]
      |> Keyword.merge(Application.get_env(:vutuv, :companies_req_options, []))

    case Req.get(options) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, binary_part(body, 0, min(byte_size(body), @max_well_known_bytes))}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      Logger.warning("company well-known fetch failed for #{url}: #{inspect(error)}")
      {:error, :exception}
  end

  defp user_agent do
    vsn = Application.spec(:vutuv, :vsn) || ~c"0"
    "vutuv/#{vsn} (+#{VutuvWeb.Endpoint.url()})"
  end
end
