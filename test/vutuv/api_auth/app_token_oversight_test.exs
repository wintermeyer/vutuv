defmodule Vutuv.ApiAuth.AppTokenOversightTest do
  @moduledoc """
  Who holds a credential for an account, and who may take it away.

  Two gaps this covers. A member's Connected apps page listed rows it gave them
  no way to tell apart — a Mastodon client registers a **new** OAuth app per
  install, so several installs are several rows of one name. And a token issued
  **for a page** was visible and revocable only to the member who issued it, so
  the page's owner could not see who was reaching it from an app.
  """
  use Vutuv.DataCase

  alias Vutuv.ApiAuth
  alias Vutuv.ApiAuth.UserAgent
  alias Vutuv.Organizations

  describe "UserAgent.label/1" do
    test "names the platform a member would recognise" do
      assert UserAgent.label("Ivory/1.0 (iPhone; iOS 18.2)") == "iPhone"
      assert UserAgent.label("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)") == "macOS"
      assert UserAgent.label("Mozilla/5.0 (Windows NT 10.0; Win64; x64)") == "Windows"
      assert UserAgent.label("Mozilla/5.0 (Linux; Android 14; Pixel 8)") == "Android"
    end

    test "an iPad is not a Mac, and an Android is not a Linux desktop" do
      # Both carry the other's marker, so the order the patterns are tried in is
      # load-bearing rather than incidental.
      assert UserAgent.label("Mozilla/5.0 (iPad; CPU OS 18_2 like Mac OS X)") == "iPad"
      assert UserAgent.label("Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X)") == "iPhone"
      assert UserAgent.label("Dalvik/2.1.0 (Linux; U; Android 13)") == "Android"
    end

    test "nothing recognisable is nil, never a guess" do
      # A client string is a self-declaration. A confident wrong device is worse
      # than "unknown device", which is at least true.
      assert UserAgent.label("some-http-library/2.1") == nil
      assert UserAgent.label(nil) == nil
    end
  end

  describe "UserAgent.capture/1" do
    test "caps the stored string so a body cannot become a row" do
      long = String.duplicate("x", UserAgent.max_chars() * 3)

      assert String.length(UserAgent.capture(long)) == UserAgent.max_chars()
    end

    test "a missing or blank header is nil, so the column says 'not recorded'" do
      assert UserAgent.capture(nil) == nil
      assert UserAgent.capture("   ") == nil
    end
  end

  describe "an organization's app tokens" do
    setup do
      owner = insert(:activated_user)
      organization = insert(:organization)

      Repo.insert!(%Vutuv.Organizations.OrganizationRole{
        organization_id: organization.id,
        user_id: owner.id,
        role: "owner"
      })

      {:ok, owner: owner, organization: organization}
    end

    defp issue(organization, user, opts \\ []) do
      app = insert(:oauth_app, user: nil, protocol: "mastodon")

      insert(:api_token,
        user: user,
        app: app,
        organization: organization,
        kind: "access",
        name: nil,
        scopes: ["read"],
        expires_at: nil,
        user_agent: Keyword.get(opts, :user_agent),
        token_hash: ApiAuth.hash_token("vutuv_at_" <> ApiAuth.random_token())
      )
    end

    test "are listed with the member who issued them", %{organization: organization} do
      issuer = insert(:activated_user)
      issue(organization, issuer)

      page = ApiAuth.organization_tokens(organization)

      assert page.total == 1
      assert [token] = page.entries
      assert token.user.id == issuer.id
    end

    test "another page's token is not among them", %{organization: organization} do
      issue(insert(:organization), insert(:activated_user))

      assert ApiAuth.organization_tokens(organization).total == 0
    end

    test "the filter narrows by the issuing member", %{organization: organization} do
      wanted = insert(:activated_user, first_name: "Zoraida")
      issue(organization, wanted)
      issue(organization, insert(:activated_user, first_name: "Other"))

      page = ApiAuth.organization_tokens(organization, "zorai")

      assert page.total == 1
      assert [%{user: %{id: id}}] = page.entries
      assert id == wanted.id
    end

    test "pages, so a large team's list stays readable", %{organization: organization} do
      per_page = ApiAuth.organization_tokens_per_page()
      for _ <- 1..(per_page + 3), do: issue(organization, insert(:activated_user))

      first = ApiAuth.organization_tokens(organization, nil, 1)
      second = ApiAuth.organization_tokens(organization, nil, 2)

      assert first.total == per_page + 3
      assert length(first.entries) == per_page
      assert length(second.entries) == 3
      assert first.pages == 2

      # No row appears on both pages.
      assert MapSet.disjoint?(
               MapSet.new(first.entries, & &1.id),
               MapSet.new(second.entries, & &1.id)
             )
    end

    test "one can be withdrawn, and only from its own page", %{organization: organization} do
      token = issue(organization, insert(:activated_user))
      foreign = insert(:organization)

      # Scoped in the query, so a foreign id is not found rather than found and
      # then refused — there is no branch left where the check can be skipped.
      assert ApiAuth.revoke_organization_token(foreign, token.id) == {:error, :not_found}
      assert ApiAuth.organization_tokens(organization).total == 1

      assert {:ok, _token} = ApiAuth.revoke_organization_token(organization, token.id)
      assert ApiAuth.organization_tokens(organization).total == 0
    end

    test "a junk id is refused rather than raising", %{organization: organization} do
      assert ApiAuth.revoke_organization_token(organization, "not-a-uuid") == {:error, :not_found}
    end

    test "turning app access off withdraws every one of them", %{
      organization: organization
    } do
      {:ok, organization} = Organizations.set_mastodon_clients(organization, true)
      for _ <- 1..3, do: issue(organization, insert(:activated_user))

      assert ApiAuth.count_organization_tokens(organization) == 3
      assert ApiAuth.revoke_organization_tokens!(organization) == 3
      assert ApiAuth.count_organization_tokens(organization) == 0
    end
  end

  describe "a member's connected apps" do
    test "say when the app was connected and from which device" do
      member = insert(:activated_user)
      app = insert(:oauth_app, user: nil, protocol: "mastodon")

      grant =
        Repo.insert!(%Vutuv.ApiAuth.Grant{user_id: member.id, app_id: app.id, scopes: ["read"]})

      insert(:api_token,
        user: member,
        app: app,
        grant: grant,
        kind: "access",
        name: nil,
        scopes: ["read"],
        expires_at: nil,
        user_agent: "Ivory/1.0 (iPhone; iOS 18.2)",
        token_hash: ApiAuth.hash_token("vutuv_at_" <> ApiAuth.random_token())
      )

      assert [listed] = ApiAuth.list_grants(member)
      assert listed.connected_at == grant.inserted_at
      assert listed.devices == ["iPhone"]
    end

    test "a grant with no recorded device simply has none" do
      member = insert(:activated_user)
      app = insert(:oauth_app, user: nil, protocol: "mastodon")
      Repo.insert!(%Vutuv.ApiAuth.Grant{user_id: member.id, app_id: app.id, scopes: ["read"]})

      assert [listed] = ApiAuth.list_grants(member)
      assert listed.devices == []
      refute is_nil(listed.connected_at)
    end
  end
end
