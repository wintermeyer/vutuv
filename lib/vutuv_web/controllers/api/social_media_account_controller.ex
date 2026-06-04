defmodule VutuvWeb.Api.SocialMediaAccountController do
  use VutuvWeb, :controller
  alias VutuvWeb.ControllerHelpers

  def index(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload([:social_media_accounts])

    render(conn, "index.json", social_media_accounts: user.social_media_accounts)
  end

  def show(conn, %{"id" => id}) do
    social_media_account = ControllerHelpers.get_owned!(conn, :social_media_accounts, id)
    render(conn, "show.json", social_media_account: social_media_account)
  end
end
