defmodule VutuvWeb.SocialMediaAccountController do
  use VutuvWeb, :controller
  alias Vutuv.Profiles.SocialMediaAccount
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.SectionDocs
  alias VutuvWeb.ControllerHelpers

  plug(VutuvWeb.Plug.AuthUser when action not in [:index, :show])

  # Index and show are also served as Markdown / text / JSON via
  # VutuvWeb.AgentDocs.SectionDocs (see agent_docs_drift_test.exs).
  def index(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload([:social_media_accounts])

    AgentDocs.respond(conn,
      html:
        &render(&1, "index.html", user: user, social_media_accounts: user.social_media_accounts),
      doc: fn ->
        SectionDocs.build_index(user, :social_media_accounts, user.social_media_accounts)
      end
    )
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
        |> redirect(to: ~p"/#{conn.assigns[:user]}/social_media_accounts")

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> render("new.html", changeset: changeset)
    end
  end

  def show(conn, %{"id" => id}) do
    social_media_account = ControllerHelpers.get_owned!(conn, :social_media_accounts, id)

    AgentDocs.respond(conn,
      html: &render(&1, "show.html", social_media_account: social_media_account),
      doc: fn ->
        SectionDocs.build_show(conn.assigns[:user], :social_media_accounts, social_media_account)
      end
    )
  end

  def edit(conn, %{"id" => id}) do
    social_media_account = ControllerHelpers.get_owned!(conn, :social_media_accounts, id)
    changeset = SocialMediaAccount.changeset(social_media_account)
    render(conn, "edit.html", social_media_account: social_media_account, changeset: changeset)
  end

  def update(conn, %{"id" => id, "social_media_account" => social_media_account_params}) do
    social_media_account = ControllerHelpers.get_owned!(conn, :social_media_accounts, id)
    changeset = SocialMediaAccount.changeset(social_media_account, social_media_account_params)

    ControllerHelpers.save(conn, Repo.update(changeset),
      flash: gettext("Social media account updated successfully."),
      redirect_to: &~p"/#{conn.assigns[:user]}/social_media_accounts/#{&1}",
      render: "edit.html",
      assigns: [social_media_account: social_media_account]
    )
  end

  def delete(conn, %{"id" => id}) do
    social_media_account = ControllerHelpers.get_owned!(conn, :social_media_accounts, id)

    # Here we use delete! (with a bang) because we expect
    # it to always work (and if it does not, it will raise).
    Repo.delete!(social_media_account)

    conn
    |> put_flash(:info, gettext("Social media account deleted successfully."))
    |> redirect(to: ~p"/#{conn.assigns[:user]}/social_media_accounts")
  end
end
