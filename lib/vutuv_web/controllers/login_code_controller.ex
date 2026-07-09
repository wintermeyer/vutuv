defmodule VutuvWeb.LoginCodeController do
  @moduledoc """
  The member's one-time login code list ("Kennwortliste", issue #912): a
  printable batch of codes, each of which signs the member in once, typed
  into the login PIN field instead of the emailed PIN.

  Like the authenticator app (`VutuvWeb.TotpController`) this lives behind
  the logged-in settings area only, so a code list is never the root of
  trust — and losing it costs nothing, the emailed PIN always keeps working.
  The list stays viewable here (it is a convenience for printing, equal in
  power to a PIN that also transits email in plain text), can be regenerated
  (replacing every code) and deleted.
  """
  use VutuvWeb, :controller

  # Routed under /settings: the pipeline (RequireLogin + SettingsUser)
  # provides :user = the logged-in member; AuthUser stays as a guard.
  plug(VutuvWeb.Plug.AuthUser)

  alias Vutuv.LoginCodes

  def index(conn, _params) do
    render(conn, "index.html",
      codes: LoginCodes.list_codes(conn.assigns[:user]),
      page_title: gettext("One-time code list (OTP)")
    )
  end

  def create(conn, _params) do
    LoginCodes.generate_list_codes(conn.assigns[:user])

    conn
    |> put_flash(
      :info,
      gettext("Your new one-time code list is ready. Print it or write it down.")
    )
    |> redirect(to: ~p"/settings/login_codes")
  end

  def delete(conn, _params) do
    LoginCodes.delete_list_codes(conn.assigns[:user])

    conn
    |> put_flash(:info, gettext("One-time code list deleted."))
    |> redirect(to: ~p"/settings/security")
  end
end
