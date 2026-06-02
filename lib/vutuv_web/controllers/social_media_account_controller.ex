defmodule VutuvWeb.SocialMediaAccountController do
  use VutuvWeb, :controller
  alias Vutuv.Profiles.SocialMediaAccount

  plug(VutuvWeb.Plug.AuthUser when action not in [:index, :show])

  def index(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload([:social_media_accounts])

    render(conn, "index.html", user: user, social_media_accounts: user.social_media_accounts)
  end

  def new(conn, _params) do
    changeset = SocialMediaAccount.changeset(%SocialMediaAccount{})
    render(conn, "new.html", changeset: changeset)
  end

  def create(conn, %{"social_media_account" => social_media_account_params}) do
    changeset =
      conn.assigns[:user]
      |> build_assoc(:social_media_accounts)
      |> SocialMediaAccount.changeset(social_media_account_params)

    case Repo.insert(changeset) do
      {:ok, social_media_account} ->
        info =
          case social_media_account.provider do
            "Twitter" ->
              gettext(
                "Social media account created successfully. Shameless plug: Follow our Twitter account @vutuv"
              )

            "GitHub" ->
              gettext(
                "Social media account created successfully. BTW: Did you know that the vutuv repo is hosted on GitHub? https://github.com/wintermeyer/vutuv"
              )

            "Instagram" ->
              gettext(
                "Social media account created successfully. Shameless plug: Check out the Instagram account of @wintermeyer"
              )

            _ ->
              gettext("Social media account created successfully.")
          end

        conn
        |> put_flash(:info, info)
        |> redirect(to: ~p"/users/#{conn.assigns[:user]}/social_media_accounts")

      {:error, changeset} ->
        render(conn, "new.html", changeset: changeset)
    end
  end

  def show(conn, %{"id" => id}) do
    social_media_account = Repo.get!(assoc(conn.assigns[:user], :social_media_accounts), id)
    render(conn, "show.html", social_media_account: social_media_account)
  end

  def edit(conn, %{"id" => id}) do
    social_media_account = Repo.get!(assoc(conn.assigns[:user], :social_media_accounts), id)
    changeset = SocialMediaAccount.changeset(social_media_account)
    render(conn, "edit.html", social_media_account: social_media_account, changeset: changeset)
  end

  def update(conn, %{"id" => id, "social_media_account" => social_media_account_params}) do
    social_media_account = Repo.get!(assoc(conn.assigns[:user], :social_media_accounts), id)
    changeset = SocialMediaAccount.changeset(social_media_account, social_media_account_params)

    case Repo.update(changeset) do
      {:ok, social_media_account} ->
        conn
        |> put_flash(:info, gettext("Social media account updated successfully."))
        |> redirect(
          to: ~p"/users/#{conn.assigns[:user]}/social_media_accounts/#{social_media_account}"
        )

      {:error, changeset} ->
        render(conn, "edit.html",
          social_media_account: social_media_account,
          changeset: changeset
        )
    end
  end

  def delete(conn, %{"id" => id}) do
    social_media_account = Repo.get!(assoc(conn.assigns[:user], :social_media_accounts), id)

    # Here we use delete! (with a bang) because we expect
    # it to always work (and if it does not, it will raise).
    Repo.delete!(social_media_account)

    conn
    |> put_flash(:info, gettext("Social media account deleted successfully."))
    |> redirect(to: ~p"/users/#{conn.assigns[:user]}/social_media_accounts")
  end
end
