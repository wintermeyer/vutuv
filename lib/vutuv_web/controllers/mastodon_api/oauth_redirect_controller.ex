defmodule VutuvWeb.MastodonApi.OauthRedirectController do
  @moduledoc """
  Legacy clients derive `/oauth/authorize` from the API host instead of reading
  OAuth metadata. Move only that browser request to the main origin, where the
  normal login session and consent screen live.
  """

  use VutuvWeb, :controller

  alias Vutuv.MastodonApi

  def authorize(conn, _params) do
    target =
      case conn.query_string do
        "" -> MastodonApi.main_url("/oauth/authorize")
        query -> MastodonApi.main_url("/oauth/authorize") <> "?" <> query
      end

    redirect(conn, external: target)
  end
end
