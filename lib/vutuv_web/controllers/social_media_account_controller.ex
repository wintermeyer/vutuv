defmodule VutuvWeb.SocialMediaAccountController do
  use VutuvWeb, :controller
  alias Vutuv.CodeStats
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
      |> Repo.preload(social_media_accounts: SocialMediaAccount.ordered())

    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "index.html",
          as_owner?: false,
          user: user,
          social_media_accounts: user.social_media_accounts
        )
      end,
      doc: fn ->
        SectionDocs.build_index(user, :social_media_accounts, user.social_media_accounts)
      end
    )
  end

  # The owner's editor (GET /settings/social_media_accounts).
  def manage(conn, _params) do
    user =
      conn.assigns[:user]
      |> Repo.preload(social_media_accounts: SocialMediaAccount.ordered())

    render(conn, "manage.html",
      user: user,
      social_media_accounts: user.social_media_accounts,
      as_owner?: true,
      page_title: gettext("Profiles")
    )
  end

  def new(conn, _params) do
    changeset = SocialMediaAccount.changeset(%SocialMediaAccount{})
    render(conn, "new.html", changeset: changeset)
  end

  def create(conn, %{"social_media_account" => social_media_account_params}) do
    user = conn.assigns[:user]

    changeset =
      user
      # New entries append to the owner's chosen order (position set on the
      # struct, never cast); reordering lives in VutuvWeb.SectionReorderLive.
      |> build_assoc(:social_media_accounts,
        position: Vutuv.Ordering.next_position(SocialMediaAccount, user.id)
      )
      |> SocialMediaAccount.changeset(social_media_account_params)

    case Repo.insert(changeset) do
      {:ok, social_media_account} ->
        # A code-forge account gets its first stats snapshot fetched in the
        # background right away (Vutuv.CodeStats), so the profile's "Code"
        # card fills without waiting for the next stale-triggered refresh.
        CodeStats.refresh_if_stale(social_media_account)

        # The GitHub wink is product-level (the vutuv source repo), so it fits
        # every installation; operator-specific plugs (the old @vutuv Twitter /
        # @wintermeyer Instagram lines) were dropped when vutuv became
        # installable by third parties.
        info =
          case social_media_account.provider do
            "GitHub" ->
              gettext(
                "Profile created successfully. BTW: Did you know that the vutuv repo is hosted on GitHub? https://github.com/wintermeyer/vutuv"
              )

            _ ->
              gettext("Profile created successfully.")
          end

        conn
        |> put_flash(:info, info)
        |> redirect(to: ~p"/settings/social_media_accounts")

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
    result = Repo.update(changeset)

    # A changed handle dropped the old snapshot (see the changeset); fetch the
    # new account's stats in the background like on create.
    with {:ok, updated} <- result, do: CodeStats.refresh_if_stale(updated)

    ControllerHelpers.save(conn, result,
      flash: gettext("Profile updated successfully."),
      redirect_to: ~p"/settings/social_media_accounts",
      render: "edit.html",
      assigns: [social_media_account: social_media_account]
    )
  end

  def delete(conn, %{"id" => id}) do
    social_media_account = ControllerHelpers.get_owned!(conn, :social_media_accounts, id)

    ControllerHelpers.delete(conn, social_media_account,
      flash: gettext("Profile deleted successfully."),
      redirect_to: ~p"/settings/social_media_accounts"
    )
  end
end
