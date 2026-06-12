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

  def index(conn, _params) do
    render(conn, "index.html", tokens: ApiAuth.list_pats(conn.assigns.current_user))
  end

  def new(conn, _params) do
    # Pre-filled so that submitting the untouched form mints a working
    # token: a dated name (several click-through tokens stay apart in the
    # list) and the quickstart scope.
    changeset =
      ApiAuth.change_pat(%{
        "name" => gettext("API token (%{date})", date: Date.to_iso8601(Date.utc_today())),
        "scopes" => ["profile:read"]
      })

    render(conn, "new.html", changeset: changeset)
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

  # Maps the form's expiry choice to a timestamp. Anything else falls
  # through to the minting chokepoint's default — every token expires
  # (see Vutuv.ApiAuth.Token.pat_changeset/2).
  defp expires_at("30"), do: days_from_now(30)
  defp expires_at("90"), do: days_from_now(90)
  defp expires_at("365"), do: days_from_now(365)
  defp expires_at(_unknown_or_missing), do: nil

  defp days_from_now(days), do: DateTime.add(DateTime.utc_now(:second), days * 86_400)
end
