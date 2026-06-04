defmodule VutuvWeb.Api.SocialMediaAccountController do
  use VutuvWeb, :controller

  def index(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload([:social_media_accounts])

    render(conn, "index.json", social_media_accounts: user.social_media_accounts)
  end

  # def create(conn, %{"social_media_account" => social_media_account_params}) do
  #   changeset = SocialMediaAccount.changeset(%SocialMediaAccount{}, social_media_account_params)

  #   case Repo.insert(changeset) do
  #     {:ok, social_media_account} ->
  #       conn
  #       |> put_status(:created)
  #       |> put_resp_header("location", api_user_social_media_account_path(conn, :show, social_media_account))
  #       |> render("show.json", social_media_account: social_media_account)
  #     {:error, changeset} ->
  #       conn
  #       |> put_status(:unprocessable_entity)
  #       |> render(Vutuv.ChangesetView, "error.json", changeset: changeset)
  #   end
  # end

  def show(conn, %{"id" => id}) do
    social_media_account = Repo.get!(assoc(conn.assigns[:user], :social_media_accounts), id)
    render(conn, "show.json", social_media_account: social_media_account)
  end

  # def update(conn, %{"id" => id, "social_media_account" => social_media_account_params}) do
  #   social_media_account = Repo.get!(SocialMediaAccount, id)
  #   changeset = SocialMediaAccount.changeset(social_media_account, social_media_account_params)

  #   case Repo.update(changeset) do
  #     {:ok, social_media_account} ->
  #       render(conn, "show.json", social_media_account: social_media_account)
  #     {:error, changeset} ->
  #       conn
  #       |> put_status(:unprocessable_entity)
  #       |> render(Vutuv.ChangesetView, "error.json", changeset: changeset)
  #   end
  # end

  # def delete(conn, %{"id" => id}) do
  #   social_media_account = Repo.get!(SocialMediaAccount, id)

  #   # Here we use delete! (with a bang) because we expect
  #   # it to always work (and if it does not, it will raise).
  #   Repo.delete!(social_media_account)

  #   send_resp(conn, :no_content, "")
  # end
end
