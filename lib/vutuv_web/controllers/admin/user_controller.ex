defmodule VutuvWeb.Admin.UserController do
  use VutuvWeb, :controller
  plug(VutuvWeb.Plug.RequireLogin)
  plug(VutuvWeb.Plug.AuthAdmin)

  alias Vutuv.Accounts.User
  alias Vutuv.Notifications.Emailer

  def update(conn, %{"user_id" => user_id}) do
    user = Repo.get!(User, user_id)
    changeset = Ecto.Changeset.cast(user, %{verified: true}, [:verified])

    case Repo.update(changeset) do
      {:ok, user} ->
        user
        |> Emailer.verification_notice()
        |> Emailer.deliver()

        conn
        |> put_flash(:info, gettext("User verified successfully."))
        |> redirect(to: ~p"/users/#{user}")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, gettext("An error occurred"))
        |> redirect(to: ~p"/users/#{user}")
    end
  end
end
