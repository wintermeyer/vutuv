defmodule VutuvWeb.Admin.LegalPageHTML do
  @moduledoc false
  use VutuvWeb, :html

  import VutuvWeb.Admin.AdminViewHelpers, only: [fmt: 1]

  embed_templates("../../templates/admin/legal_page/*")

  @doc "The human name of a legal page (fixed set, keyed by slug)."
  def page_name("impressum"), do: gettext("Impressum")
  def page_name("datenschutzerklaerung"), do: gettext("Datenschutzerklärung")
  def page_name("nutzungsbedingungen"), do: gettext("Nutzungsbedingungen")

  @doc "The public path a legal page is served under."
  def page_path("impressum"), do: ~p"/impressum"
  def page_path("datenschutzerklaerung"), do: ~p"/datenschutzerklaerung"
  def page_path("nutzungsbedingungen"), do: ~p"/nutzungsbedingungen"
end
