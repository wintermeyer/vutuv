defmodule VutuvWeb.Plug.MastodonApiAuth do
  @moduledoc """
  Bearer-token and scope enforcement for authenticated Mastodon API routes.
  Errors deliberately use Mastodon's compact JSON shape rather than the native
  API's RFC 9457 documents.
  """

  import Plug.Conn

  alias Vutuv.ApiAuth
  alias Vutuv.MastodonApi.Access
  alias Vutuv.MastodonApi.Scopes
  alias VutuvWeb.MastodonApi.Errors

  def init(opts), do: opts

  def call(conn, _opts) do
    case bearer_token(conn) do
      token when is_binary(token) -> authenticate(conn, token)
      _missing -> error(conn, 401, "The access token is invalid")
    end
  end

  defp authenticate(conn, plaintext) do
    case ApiAuth.verify_token(plaintext) do
      {:ok, api_token, user} -> authorize(conn, api_token, user)
      _invalid -> error(conn, 401, "The access token is invalid")
    end
  end

  defp authorize(conn, api_token, user) do
    if mastodon_token?(api_token) do
      authorize_subject(conn, api_token, user)
    else
      error(conn, 401, "The access token is invalid")
    end
  end

  defp authorize_subject(conn, api_token, user) do
    required = conn.assigns.mastodon_scope

    with {:ok, organization} <- Access.authorize_token(api_token, user),
         true <- Scopes.granted?(api_token.scopes, required),
         [^required] <- Access.allowed_scopes(user, organization, [required]) do
      conn
      |> assign(:current_user, user)
      |> assign(:current_organization, organization)
      |> assign(:api_token, api_token)
      |> assign(:api_scopes, api_token.scopes)
    else
      {:error, :access_disabled} -> error(conn, 403, "Mastodon client access is disabled")
      _other -> error(conn, 403, "This action is outside the authorized scopes")
    end
  end

  defp mastodon_token?(%{app: %{protocol: "mastodon"}}), do: true
  defp mastodon_token?(_token), do: false

  @doc false
  # Public because `MastodonApi.AppController` authenticates its app-token
  # endpoint itself and must not spell the header a second, stricter way. The
  # reading itself lives in `ControllerHelpers` — that comment was written
  # against one copy and there were three.
  defdelegate bearer_token(conn), to: VutuvWeb.ControllerHelpers

  # The adapter's error shape comes from `Errors`; only the `halt/1` is this
  # plug's own, since a plug that refuses must stop the pipeline.
  defp error(conn, status, message),
    do: conn |> Errors.error(status, message) |> halt()
end
