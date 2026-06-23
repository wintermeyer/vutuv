defmodule VutuvWeb.UnsubscribeController do
  @moduledoc """
  Switching notification emails off without a login. The GET renders a
  confirmation page (a human clicking the email's footer link), the POST
  flips the switch — that page's button and the mail providers' RFC 8058
  one-click POST alike. The signed token (`VutuvWeb.UnsubscribeToken`) is the
  only authorization; anything else 404s. The routes deliberately live
  outside CSRF protection (see the `:unsubscribe` pipeline): the one-click
  POST carries no token, which is safe because the capability is in the URL
  and the action only ever switches one boolean off.
  """

  use VutuvWeb, :controller

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias VutuvWeb.UnsubscribeToken

  def show(conn, %{"token" => token}) do
    case user_for_token(token) do
      {%User{} = user, field} -> render(conn, "show.html", user: user, token: token, field: field)
      _ -> VutuvWeb.ControllerHelpers.render_error(conn, 404)
    end
  end

  def create(conn, %{"token" => token}) do
    with {%User{} = user, field} <- user_for_token(token),
         {:ok, user} <- Accounts.set_email_pref(user, field, false) do
      render(conn, "done.html", user: user, field: field)
    else
      _ -> VutuvWeb.ControllerHelpers.render_error(conn, 404)
    end
  end

  # The token names both the user and the single preference field it may switch
  # off (a legacy id-only token resolves to :notification_emails?).
  defp user_for_token(token) do
    case UnsubscribeToken.verify(token) do
      {:ok, user_id, field} ->
        case Accounts.get_user(user_id) do
          %User{} = user -> {user, field}
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
