defmodule VutuvWeb.TotpController do
  @moduledoc """
  Set up and turn off the authenticator-app login (issue #912).

  Enrolment happens here, from the logged-in settings area — and only here,
  like a passkey (`VutuvWeb.PasskeyController`): reaching this controller
  requires a member who already proved they own their email by typing an
  emailed PIN at least once, so an app code is always a faster *return*
  login, never the root of trust.

  Two steps: `new` mints (or resumes) the pending secret and shows it as a QR
  code, `create` checks the first code the member's app produced and only
  then turns the enrolment on — so a mis-scanned QR code can never lock the
  member into an app that shows wrong codes. Turning it off is one click;
  the emailed PIN is unaffected throughout.
  """
  use VutuvWeb, :controller

  # Routed under /settings: the pipeline (RequireLogin + SettingsUser)
  # provides :user = the logged-in member; AuthUser stays as a guard.
  plug(VutuvWeb.Plug.AuthUser)

  alias Vutuv.LoginCodes

  def new(conn, _params) do
    user = conn.assigns[:user]

    case LoginCodes.start_totp_enrollment(user) do
      {:ok, totp} ->
        render_new(conn, user, totp)

      {:error, :already_enabled} ->
        conn
        |> put_flash(:info, gettext("Your authenticator app is already set up."))
        |> redirect(to: ~p"/settings/security")
    end
  end

  def create(conn, params) do
    user = conn.assigns[:user]
    code = get_in(params, ["totp", "code"]) || ""

    case LoginCodes.confirm_totp(user, code) do
      {:ok, _totp} ->
        conn
        |> put_flash(
          :info,
          gettext(
            "Authenticator app set up. When you log in, the code from your app now works in the PIN field."
          )
        )
        |> redirect(to: ~p"/settings/security")

      {:error, :invalid_code} ->
        # Keep the pending secret (the member already scanned it) and let them
        # retry with the code their app shows right now.
        {:ok, totp} = LoginCodes.start_totp_enrollment(user)

        conn
        |> put_flash(
          :error,
          gettext("That code didn't match. Please try again with the code your app shows now.")
        )
        |> render_new(user, totp)

      {:error, :not_started} ->
        redirect(conn, to: ~p"/settings/totp/new")
    end
  end

  def delete(conn, _params) do
    LoginCodes.disable_totp(conn.assigns[:user])

    conn
    |> put_flash(:info, gettext("Authenticator app turned off."))
    |> redirect(to: ~p"/settings/security")
  end

  defp render_new(conn, user, totp) do
    render(conn, "new.html",
      otpauth_uri: LoginCodes.otpauth_uri(user, totp),
      manual_secret: LoginCodes.manual_entry_secret(totp),
      page_title: gettext("Authenticator app")
    )
  end
end
