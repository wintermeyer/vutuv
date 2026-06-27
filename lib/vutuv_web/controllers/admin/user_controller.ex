defmodule VutuvWeb.Admin.UserController do
  use VutuvWeb, :controller

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User

  # The member browser itself is a LiveView (`VutuvWeb.Admin.UserLive`); this
  # controller keeps only the identity-verification write action, which the
  # LiveView's inline Verify button and this legacy POST both route through
  # `Accounts.verify_identity/1`.
  def update(conn, %{"user_id" => user_id}) do
    user = Repo.get!(User, user_id)

    case Accounts.verify_identity(user) do
      {:ok, user} ->
        conn
        |> put_flash(:info, gettext("User verified successfully."))
        |> redirect(to: ~p"/#{user}")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, gettext("An error occurred"))
        |> redirect(to: ~p"/#{user}")
    end
  end
end
