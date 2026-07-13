defmodule Vutuv.Organizations.Verification do
  @moduledoc """
  The two domain-proof methods behind verified organization pages (issue #929), both
  proving control of the DOMAIN itself (never merely an address on it):

    * `dns` — a `vutuv-organization-verify=<token>` TXT record.
    * `well_known` — the token served at
      `https://domain/.well-known/vutuv-organization-verify.txt`.

  The proof mechanics live in `Vutuv.WebVerification` (shared with verified
  personal-webpage links); this module is the organization-flavoured wrapper that
  owns the **organization verification scheme** (the `vutuv-organization-verify=` DNS
  prefix and the `/.well-known/vutuv-organization-verify.txt` file — deliberately
  distinct from the `vutuv-verify=` scheme personal-webpage links use, so a
  proof for a link never doubles as a proof for an organization on the same host),
  the organization outbound-call gate (`:verify_organization_domains`) and the organization
  test seams (`:organizations_dns_resolver` / `:organizations_req_options`). Off =
  organization domain verification is disabled on this installation (no outbound
  calls).
  """

  alias Vutuv.WebVerification

  @dns_prefix "vutuv-organization-verify="
  @well_known_path "/.well-known/vutuv-organization-verify.txt"

  @doc "Whether the domain-proof methods are enabled for this installation."
  def enabled? do
    Application.get_env(:vutuv, :verify_organization_domains, true)
  end

  @doc "A fresh unguessable verification token (~192 bits, URL-safe)."
  def gen_token, do: WebVerification.gen_token()

  # --- DNS TXT ----------------------------------------------------------------

  @doc "The exact TXT record value a member must publish for the `dns` method."
  def dns_txt_value(token), do: WebVerification.dns_txt_value(@dns_prefix, token)

  @doc "The CNAME-safe alternate name (`_vutuv.<host>`) the `dns` TXT record may also live at."
  def dns_challenge_name(host), do: WebVerification.dns_challenge_name(host)

  @doc "Whether `host` publishes a `vutuv-organization-verify=<token>` TXT record."
  def dns_verified?(host, token) when is_binary(host) and is_binary(token) do
    WebVerification.dns_verified?(host, @dns_prefix, token, dns_resolver())
  end

  # --- well-known file --------------------------------------------------------

  @doc "The URL fetched for the `well_known` method."
  def well_known_url(host), do: WebVerification.well_known_url(host, @well_known_path)

  @doc """
  Whether `https://host/.well-known/vutuv-organization-verify.txt` serves exactly `token`.
  """
  def well_known_verified?(host, token) when is_binary(host) and is_binary(token) do
    WebVerification.well_known_verified?(host, @well_known_path, token, req_options())
  end

  defp dns_resolver do
    Application.get_env(
      :vutuv,
      :organizations_dns_resolver,
      &WebVerification.default_txt_lookup/1
    )
  end

  defp req_options do
    Application.get_env(:vutuv, :organizations_req_options, [])
  end
end
