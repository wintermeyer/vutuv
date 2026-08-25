defmodule VutuvWeb.Admin.UserController do
  use VutuvWeb, :controller

  alias Vutuv.Accounts
  alias VutuvWeb.ControllerHelpers

  # The member browser itself is a LiveView (`VutuvWeb.Admin.UserLive`); this
  # controller keeps only the identity-verification write action, which the
  # LiveView's inline Verify button and this legacy POST both route through
  # `Accounts.verify_identity/1`.
  def update(conn, %{"user_id" => user_id}) do
    # `get_user/1` rather than `Repo.get!`: a malformed id off an admin URL is a
    # 404, not an `Ecto.CastError` 500.
    case ControllerHelpers.get_user(user_id) do
      nil -> ControllerHelpers.render_error(conn, 404)
      user -> verify(conn, user)
    end
  end

  defp verify(conn, user) do
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
