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
      %User{} = user -> render(conn, "show.html", user: user, token: token)
      _ -> VutuvWeb.ControllerHelpers.render_error(conn, 404)
    end
  end

  def create(conn, %{"token" => token}) do
    with %User{} = user <- user_for_token(token),
         {:ok, user} <- Accounts.set_notification_emails(user, false) do
      render(conn, "done.html", user: user)
    else
      _ -> VutuvWeb.ControllerHelpers.render_error(conn, 404)
    end
  end

  defp user_for_token(token) do
    case UnsubscribeToken.verify(token) do
      {:ok, user_id} -> Accounts.get_user(user_id)
      _ -> nil
    end
  end
end
