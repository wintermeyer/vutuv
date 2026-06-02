defmodule VutuvWeb.Api.SocialMediaAccountJSON do
  @moduledoc false
  import VutuvWeb.Api.ApiHelpers

  @attributes ~w(provider value)a

  def render("index.json", %{social_media_accounts: social_media_accounts}) do
    %{data: Enum.map(social_media_accounts, &social_media_account/1)}
  end

  def render("index_lite.json", %{social_media_accounts: social_media_accounts}) do
    %{data: Enum.map(social_media_accounts, &social_media_account_lite/1)}
  end

  def render("show.json", %{social_media_account: social_media_account}) do
    %{data: social_media_account(social_media_account)}
  end

  def render("show_lite.json", %{social_media_account: social_media_account}) do
    %{data: social_media_account_lite(social_media_account)}
  end

  def social_media_account(social_media_account) do
    social_media_account_lite(social_media_account)
    |> put_attributes(social_media_account, @attributes)
  end

  def social_media_account_lite(social_media_account) do
    %{id: social_media_account.id, type: "social_media_account"}
  end
end
