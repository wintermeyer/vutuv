defmodule VutuvWeb.SessionController do
  use VutuvWeb, :controller

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Chat
  alias VutuvWeb.RateLimit

  # The login page is logged-out-only, like registration. An already-logged-in
  # visitor is redirected to their profile. :delete (logout) stays unguarded.
  plug(VutuvWeb.Plug.RequireUserLoggedOut when action in [:new, :create])

  def new(conn, _) do
    render(conn, "new.html")
  end

  # Step 1: the visitor types their email. We mail a PIN, stash the identity in
  # the signed cookie and render the PIN-entry form in the same tab.
  def create(conn, %{"session" => %{"email" => email}}) do
    case RateLimit.check(conn, :login_email, email) do
      :ok ->
        case Accounts.login_by_email(conn, email) do
          {:ok, conn} ->
            render(conn, "pin_user_login.html")

          {:error, _reason, conn} ->
            conn
            |> put_flash(:error, gettext("Invalid email"))
            |> render("new.html")
        end

      :rate_limited ->
        conn
        |> put_flash(:error, gettext("Too many attempts. Please try again later."))
        |> render("new.html")
    end
  end

  # Step 2: the visitor types the PIN. Identity comes from the signed cookie.
  # The post-registration confirmation form marks itself with a context so the
  # greeting fits a first-time member (cosmetic only, so client-set is fine).
  def create(conn, %{"session" => %{"pin" => pin} = session}) do
    with :ok <- RateLimit.check(conn, :login_pin),
         email when is_binary(email) <- Accounts.read_pin_cookie(conn) do
      verify_login_pin(conn, email, pin, session["context"])
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

  defp verify_login_pin(conn, email, pin, context) do
    case Accounts.check_pin(email, pin, "login") do
      # correct, drop cookie, log the user in
      {:ok, user} ->
        Accounts.login(conn, user)
        |> Accounts.delete_pin_cookie()
        |> put_flash(:info, welcome_flash(context, user))
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

  # First-time sign-ups get their own greeting; returning members get a
  # personal one with their name and, when they have any, a nudge about the
  # conversations waiting for them (the same count the shell's message badge
  # shows, so the two never disagree).
  defp welcome_flash("registration", _user), do: gettext("Welcome to vutuv!")

  defp welcome_flash(_context, %User{} = user) do
    [greeting(user), unread_note(user)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp greeting(%User{first_name: name}) when is_binary(name) and name != "" do
    gettext("Welcome back, %{name}!", name: name)
  end

  defp greeting(_user), do: gettext("Welcome back!")

  defp unread_note(%User{} = user) do
    case Chat.unread_conversations_count(user) do
      0 ->
        nil

      count ->
        ngettext(
          "You have %{count} new message.",
          "You have %{count} new messages.",
          count
        )
    end
  end
end
