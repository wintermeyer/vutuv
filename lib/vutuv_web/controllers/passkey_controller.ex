defmodule VutuvWeb.PasskeyController do
  @moduledoc """
  Enrol and manage the owner's passkeys (issue #795).

  A passkey is enrolled here, from the logged-in Account hub — and only here.
  There is no "register with a passkey" path: reaching this controller requires
  an `email_confirmed?` member (the same `UserResolveSlug` + `AuthUser` +
  `EnsureActivated` owner gate the settings pages use), i.e. someone who has
  already proved they own their email by typing an emailed PIN at least once. So
  a passkey is always a faster *return* login, never the root of trust.

  Enrolment is the two-request WebAuthn ceremony driven by
  `assets/js/webauthn.js`: `challenge` mints a registration challenge (stored in
  the session), `create` verifies the attestation and persists the credential.
  Both answer JSON; the JS fetch must not send `Accept: application/json`. The
  list itself is rendered on the Account hub (`SettingsController.index`);
  `delete` removes one passkey.
  """
  use VutuvWeb, :controller

  # Routed under /settings: the pipeline (RequireLogin + SettingsUser +
  # EnsureActivated) provides :user = the logged-in member; AuthUser stays as
  # a belt-and-braces guard.
  plug(VutuvWeb.Plug.AuthUser)

  alias Vutuv.Credentials
  alias Vutuv.Sessions

  # Step 1: a registration challenge for the owner plus the browser create()
  # options, with the member's existing passkeys excluded so the same
  # authenticator cannot be enrolled twice.
  def challenge(conn, _params) do
    user = conn.assigns[:user]
    {challenge, options} = Credentials.registration_options(user)

    conn
    |> put_session(:webauthn_reg_challenge, challenge)
    |> json(options)
  end

  # Step 2: verify the attestation against the stored challenge and persist the
  # passkey. The nickname defaults to the device summary when left blank, the
  # same label the signed-in-devices list shows.
  def create(conn, params) do
    user = conn.assigns[:user]
    challenge = get_session(conn, :webauthn_reg_challenge)
    nickname = passkey_nickname(conn, params)
    conn = delete_session(conn, :webauthn_reg_challenge)

    case challenge && Credentials.register(user, challenge, params, nickname) do
      {:ok, _credential} ->
        conn
        |> put_flash(:info, gettext("Passkey added."))
        |> json(%{ok: true, redirect: ~p"/settings/security"})

      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{ok: false, error: gettext("That passkey could not be registered.")})
    end
  end

  # Remove one passkey. Only the owner's own credentials are reachable
  # (Credentials.get_for_user/2 scopes by user); an unknown/foreign id is a quiet
  # no-op redirect. Removing the last passkey is fine — email-PIN stays available.
  def delete(conn, %{"id" => id}) do
    user = conn.assigns[:user]

    case Credentials.get_for_user(user, id) do
      nil -> nil
      credential -> Credentials.delete(credential)
    end

    conn
    |> put_flash(:info, gettext("Passkey removed."))
    |> redirect(to: ~p"/settings/security")
  end

  defp passkey_nickname(conn, params) do
    case params["nickname"] do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> default_nickname(conn)
          trimmed -> trimmed
        end

      _ ->
        default_nickname(conn)
    end
  end

  defp default_nickname(conn) do
    conn |> get_req_header("user-agent") |> List.first() |> Sessions.device_summary()
  end
end
