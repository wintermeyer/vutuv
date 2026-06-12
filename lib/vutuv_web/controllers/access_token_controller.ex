defmodule VutuvWeb.AccessTokenController do
  @moduledoc """
  The user's personal access tokens for `/api/2.0` (see `Vutuv.ApiAuth`):
  list, create, revoke one, revoke all. The token value is carried to the
  list page in a one-shot flash and shown exactly once; revocation cuts the
  token's access on its very next request.
  """

  use VutuvWeb, :controller

  alias Vutuv.ApiAuth

  plug(VutuvWeb.Plug.RequireLoginOr404)

  @expiry_days %{"30" => 30, "90" => 90, "365" => 365}

  def index(conn, _params) do
    render(conn, "index.html", tokens: ApiAuth.list_pats(conn.assigns.current_user))
  end

  def new(conn, _params) do
    render(conn, "new.html", changeset: ApiAuth.change_pat())
  end

  def create(conn, %{"token" => params}) do
    attrs = %{
      "name" => params["name"],
      "scopes" => params["scopes"] || [],
      "expires_at" => expires_at(params["expires_in"])
    }

    case ApiAuth.create_pat(conn.assigns.current_user, attrs) do
      {:ok, plaintext, _token} ->
        conn
        |> put_flash(:new_token, plaintext)
        |> redirect(to: ~p"/access_tokens")

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> render("new.html", changeset: changeset)
    end
  end

  def delete(conn, %{"id" => id}) do
    case ApiAuth.get_pat(conn.assigns.current_user, id) do
      nil ->
        VutuvWeb.ControllerHelpers.render_error(conn, 404)

      token ->
        ApiAuth.revoke_token!(token)

        conn
        |> put_flash(:info, gettext("The token \"%{name}\" no longer works.", name: token.name))
        |> redirect(to: ~p"/access_tokens")
    end
  end

  def delete_all(conn, _params) do
    count = ApiAuth.revoke_all_tokens!(conn.assigns.current_user)

    conn
    |> put_flash(
      :info,
      ngettext("One token was revoked.", "%{count} tokens were revoked.", count)
    )
    |> redirect(to: ~p"/access_tokens")
  end

  defp expires_at(choice) when is_map_key(@expiry_days, choice) do
    DateTime.add(DateTime.utc_now(:second), @expiry_days[choice] * 86_400)
  end

  defp expires_at(_never_or_missing), do: nil
end
