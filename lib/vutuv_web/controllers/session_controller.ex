defmodule VutuvWeb.SessionController do
  use VutuvWeb, :controller

  def new(conn, _) do
    render(conn, "new.html", body_class: "stretch")
  end

  def create(conn, %{"session" => %{"email" => email}}) do
    case Vutuv.Accounts.login_by_email(conn, email) do
      {:ok, conn} ->
        case conn.cookies["_vutuv_fbs_temp"] do
          nil ->
            conn
            |> render("user_login.html", body_class: "stretch")

          _ ->
            conn
            |> render("pin_user_login.html", body_class: "stretch")
        end

      {:error, _reason, conn} ->
        conn
        |> put_flash(:error, gettext("Invalid email"))
        |> render("new.html", body_class: "stretch")
    end
  end

  def create(conn, %{"session" => %{"pin" => pin}}) do
    conn
    |> unform_pin_cookie
    |> Vutuv.Accounts.check_pin(pin, "login")
    |> case do
      # correct, delete cookie, login user
      {:ok, user} ->
        Vutuv.Accounts.login(conn, user)
        |> delete_resp_cookie("_vutuv_fbs_temp", max_age: 1800)
        |> put_flash(:info, gettext("Welcome back!"))
        |> redirect(to: ~p"/users/#{user}")

      # incorrect, inform user
      {:error, reason} ->
        conn
        |> put_flash(:error, reason)
        |> redirect(to: ~p"/")

      # locked out, delete cookie
      {:expired, message} ->
        conn
        |> delete_resp_cookie("_vutuv_fbs_temp", max_age: 1800)
        |> put_flash(:error, message)
        |> redirect(to: ~p"/sessions/new")

      # locked out, delete cookie
      :lockout ->
        conn
        |> delete_resp_cookie("_vutuv_fbs_temp", max_age: 1800)
        |> put_flash(:error, gettext("Too many incorrect attempts."))
        |> redirect(to: ~p"/sessions/new")
    end
  end

  def show(conn, %{"magiclink" => link}) do
    case Vutuv.Accounts.check_magic_link(link, "login") do
      {:ok, user} ->
        Vutuv.Accounts.login(conn, user)
        |> put_flash(:info, gettext("Welcome back!"))
        |> redirect(to: ~p"/users/#{user}")

      {:error, reason} ->
        conn
        |> put_flash(:error, reason)
        |> redirect(to: ~p"/")
    end
  end

  def delete(conn, _) do
    user = conn.assigns[:current_user]

    conn
    |> Vutuv.Accounts.logout()
    |> redirect(to: ~p"/users/#{user}")
  end

  defp unform_pin_cookie(%{cookies: %{"_vutuv_fbs_temp" => payload}} = conn) do
    salt = Application.fetch_env!(:vutuv, VutuvWeb.Endpoint)[:secret_key_base]
    {:ok, email} = Phoenix.Token.verify(conn, salt, payload)
    email
  end
end
