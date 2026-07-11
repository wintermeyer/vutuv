defmodule Vutuv.Companies.Verification do
  @moduledoc """
  The two domain-proof methods behind verified company pages (issue #929), both
  proving control of the DOMAIN itself (never merely an address on it):

    * `dns` — a `vutuv-verify=<token>` TXT record.
    * `well_known` — the token served at
      `https://domain/.well-known/vutuv-verify.txt`.

  The proof mechanics live in `Vutuv.WebVerification` (shared with verified
  personal-webpage links); this module is the company-flavoured wrapper that
  owns the company outbound-call gate (`:verify_company_domains`) and the
  company test seams (`:companies_dns_resolver` / `:companies_req_options`).
  Off = company domain verification is disabled on this installation (no
  outbound calls).
  """

  alias Vutuv.WebVerification

  @doc "Whether the domain-proof methods are enabled for this installation."
  def enabled? do
    Application.get_env(:vutuv, :verify_company_domains, true)
  end

  @doc "A fresh unguessable verification token (~192 bits, URL-safe)."
  def gen_token, do: WebVerification.gen_token()

  # --- DNS TXT ----------------------------------------------------------------

  @doc "The exact TXT record value a member must publish for the `dns` method."
  def dns_txt_value(token), do: WebVerification.dns_txt_value(token)

  @doc "Whether `host` publishes a `vutuv-verify=<token>` TXT record."
  def dns_verified?(host, token) when is_binary(host) and is_binary(token) do
    WebVerification.dns_verified?(host, token, dns_resolver())
  end

  # --- well-known file --------------------------------------------------------

  @doc "The URL fetched for the `well_known` method."
  def well_known_url(host), do: WebVerification.well_known_url(host)

  @doc """
  Whether `https://host/.well-known/vutuv-verify.txt` serves exactly `token`.
  """
  def well_known_verified?(host, token) when is_binary(host) and is_binary(token) do
    WebVerification.well_known_verified?(host, token, req_options())
  end

  defp dns_resolver do
    Application.get_env(:vutuv, :companies_dns_resolver, &WebVerification.default_txt_lookup/1)
  end

  defp req_options do
    Application.get_env(:vutuv, :companies_req_options, [])
  end
end
