defmodule VutuvWeb.SocialMediaAccountController do
  use VutuvWeb, :controller
  alias Vutuv.CodeStats
  alias Vutuv.Profiles.SocialAccountVerification, as: Verification
  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.SourceRepo
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.SectionDocs
  alias VutuvWeb.ControllerHelpers

  plug(VutuvWeb.Plug.AuthUser when action not in [:index, :show])

  # Index and show are also served as Markdown / text / JSON via
  # VutuvWeb.AgentDocs.SectionDocs (see agent_docs_drift_test.exs).
  def index(conn, _params) do
    user = user_with_social_media_accounts(conn)

    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "index.html",
          as_owner?: false,
          user: user,
          social_media_accounts: user.social_media_accounts,
          page_title: VutuvWeb.UserHelpers.member_page_title(user, gettext("Profiles"))
        )
      end,
      doc: fn ->
        SectionDocs.build_index(user, :social_media_accounts, user.social_media_accounts)
      end
    )
  end

  # The owner's editor (GET /settings/social_media_accounts).
  def manage(conn, _params) do
    user = user_with_social_media_accounts(conn)

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
      |> check_instance(conn)

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
                "Profile created successfully. BTW: Did you know that the vutuv repo is hosted on GitHub? %{url}",
                url: SourceRepo.url()
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
      html:
        &render(&1, "show.html",
          social_media_account: social_media_account,
          page_title:
            VutuvWeb.UserHelpers.member_page_title(
              conn.assigns[:user],
              social_media_account.provider
            )
        ),
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

    changeset =
      social_media_account
      |> SocialMediaAccount.changeset(social_media_account_params)
      |> check_instance(conn)

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

  # "This account is really mine": the instructions page. A member puts their
  # vutuv profile URL in the account's bio and comes back here to have it
  # checked, so an immediate check on save would be pointless — the bio has not
  # been edited yet at that moment.
  def verify(conn, %{"id" => id}) do
    account = ControllerHelpers.get_owned!(conn, :social_media_accounts, id)
    user = conn.assigns[:user]

    render(conn, "verify.html",
      user: user,
      social_media_account: account,
      enabled?: Verification.enabled?(),
      verifiable?: Verification.verifiable?(account),
      profile_url: Verification.expected_url(user),
      page_title: gettext("Verify profile")
    )
  end

  def run_verify(conn, %{"id" => id}) do
    account = ControllerHelpers.get_owned!(conn, :social_media_accounts, id)

    conn
    |> verify_result(Verification.verify(account, conn.assigns[:user]))
    |> redirect(to: verify_path(account))
  end

  defp verify_result(conn, {:ok, _updated}) do
    put_flash(conn, :info, gettext("Profile verified. It now shows a verified mark."))
  end

  defp verify_result(conn, {:error, :disabled}) do
    put_flash(
      conn,
      :error,
      gettext("Profile verification is disabled on this installation.")
    )
  end

  defp verify_result(conn, {:error, :unsupported}) do
    put_flash(conn, :error, gettext("This network cannot be verified."))
  end

  defp verify_result(conn, {:error, :unreachable}) do
    put_flash(
      conn,
      :error,
      gettext("We could not reach the network just now. Please try again in a moment.")
    )
  end

  # Deliberately says "profile" rather than naming a field: which field carries
  # the proof depends on the network (a Bluesky bio, a forge's website field or
  # its description), and the instructions page above the button has just said
  # which one this member should use.
  defp verify_result(conn, {:error, :not_found}) do
    put_flash(
      conn,
      :error,
      gettext("We could not find the link in your profile yet. Please try again.")
    )
  end

  defp verify_path(account), do: ~p"/settings/social_media_accounts/#{account}/verify"

  # A self-hosted Gitea/Forgejo entry is only accepted once that instance
  # confirms the username (Vutuv.CodeStats.verify_instance/1) — the check that
  # keeps a member-named forge from being a free-text field. Everything else
  # passes straight through, so no other provider pays for a network round trip
  # on save. The rate limit is asked first, and only when a probe would really
  # be sent, so a slot is never spent on a save that asks nobody anything.
  defp check_instance(changeset, conn),
    do: ControllerHelpers.verify_forge_instance(changeset, conn, conn.assigns[:user])

  defp user_with_social_media_accounts(conn),
    do:
      Repo.preload(conn.assigns[:user],
        social_media_accounts: SocialMediaAccount.ordered()
      )
end
