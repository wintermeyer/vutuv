defmodule VutuvWeb.SessionController do
  use VutuvWeb, :controller

  alias Vutuv.Accounts
  alias VutuvWeb.RateLimit

  # The login page is logged-out-only, like registration. An already-logged-in
  # visitor is redirected to their profile. :delete (logout) stays unguarded.
  plug(VutuvWeb.Plug.RequireUserLoggedOut when action in [:new, :create])

  def new(conn, _) do
    render(conn, "new.html", body_class: "stretch")
  end

  # Step 1: the visitor types their email. We mail a PIN, stash the identity in
  # the signed cookie and render the PIN-entry form in the same tab.
  def create(conn, %{"session" => %{"email" => email}}) do
    case RateLimit.check(conn, :login_email, email) do
      :ok ->
        case Accounts.login_by_email(conn, email) do
          {:ok, conn} ->
            render(conn, "pin_user_login.html", body_class: "stretch")

          {:error, _reason, conn} ->
            conn
            |> put_flash(:error, gettext("Invalid email"))
            |> render("new.html", body_class: "stretch")
        end

      :rate_limited ->
        conn
        |> put_flash(:error, gettext("Too many attempts. Please try again later."))
        |> render("new.html", body_class: "stretch")
    end
  end

  # Step 2: the visitor types the PIN. Identity comes from the signed cookie.
  def create(conn, %{"session" => %{"pin" => pin}}) do
    with :ok <- RateLimit.check(conn, :login_pin),
         email when is_binary(email) <- Accounts.read_pin_cookie(conn) do
      verify_login_pin(conn, email, pin)
    else
      :rate_limited ->
        conn
        |> put_flash(:error, gettext("Too many attempts. Please try again later."))
        |> redirect(to: ~p"/login")

      nil ->
        conn
        |> put_flash(:error, gettext("Your login session expired. Please try again."))
        |> redirect(to: ~p"/login")
    end
  end

  def delete(conn, _) do
    user = conn.assigns[:current_user]

    conn
    |> Accounts.logout()
    |> redirect(to: ~p"/#{user}")
  end

  defp verify_login_pin(conn, email, pin) do
    case Accounts.check_pin(email, pin, "login") do
      # correct, drop cookie, log the user in
      {:ok, user} ->
        Accounts.login(conn, user)
        |> Accounts.delete_pin_cookie()
        |> put_flash(:info, gettext("Welcome back!"))
        |> redirect(to: ~p"/#{user}")

      # incorrect, let them retry
      {:error, reason} ->
        conn
        |> put_flash(:error, reason)
        |> redirect(to: ~p"/")

      # expired, drop cookie
      {:expired, message} ->
        conn
        |> Accounts.delete_pin_cookie()
        |> put_flash(:error, message)
        |> redirect(to: ~p"/login")

      # locked out, drop cookie
      :lockout ->
        conn
        |> Accounts.delete_pin_cookie()
        |> put_flash(:error, gettext("Too many incorrect attempts."))
        |> redirect(to: ~p"/login")
    end
  end
end
