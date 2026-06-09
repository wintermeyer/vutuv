defmodule VutuvWeb.Admin.UserController do
  use VutuvWeb, :controller

  alias Vutuv.Accounts.User
  alias Vutuv.Notifications.Emailer

  def update(conn, %{"user_id" => user_id}) do
    user = Repo.get!(User, user_id)
    changeset = Ecto.Changeset.cast(user, %{identity_verified?: true}, [:identity_verified?])

    case Repo.update(changeset) do
      {:ok, user} ->
        user
        |> Emailer.verification_notice()
        |> Emailer.deliver()

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
