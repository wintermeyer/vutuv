defmodule VutuvWeb.OauthHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../templates/oauth/*")

  def error_text(:unknown_client),
    do: gettext("The application is unknown. Its developer needs to check the client_id.")

  def error_text(:invalid_redirect_uri),
    do:
      gettext(
        "The redirect address is not registered for this application. Its developer needs to register it first."
      )

  def error_text(:app_suspended),
    do: gettext("This application has been suspended.")

  def error_text(:invalid_scope),
    do: gettext("The application asked for unknown permissions.")

  def error_text(:invalid_pkce),
    do: gettext("The application's request is missing the required PKCE challenge (S256).")

  def error_text(_other),
    do: gettext("The authorization request is invalid.")
end
