defmodule VutuvWeb.FediverseGroundworkTest do
  # Step 1 towards the Fediverse, deliberately protocol-free: rel="me"
  # identity links (Mastodon's built-in verification) plus the per-member
  # opt-in flag future federation will be gated on. Nothing federates yet.
  use VutuvWeb.ConnCase, async: true

  describe "rel=me head links on the profile" do
    test "each linkable social account gets a <link rel=me> in the head", %{conn: conn} do
      user = insert(:activated_user)

      insert(:social_media_account,
        user: user,
        provider: "Mastodon",
        value: "alice@mastodon.social"
      )

      insert(:social_media_account, user: user, provider: "GitHub", value: "alicehub")

      body = conn |> get(~p"/#{user}") |> html_response(200)

      assert body =~ ~s(<link rel="me" href="https://mastodon.social/@alice")
      assert body =~ ~r|<link rel="me" href="https://github\.com/alicehub|
    end

    test "a handle-only provider (no canonical URL) gets no head link", %{conn: conn} do
      user = insert(:activated_user)
      insert(:social_media_account, user: user, provider: "Snapchat", value: "alice.snap")

      body = conn |> get(~p"/#{user}") |> html_response(200)

      refute body =~ ~s(<link rel="me")
    end

    test "a profile without social accounts carries no rel=me head link", %{conn: conn} do
      user = insert(:activated_user)

      body = conn |> get(~p"/#{user}") |> html_response(200)

      refute body =~ ~s(<link rel="me")
    end
  end

  describe "the Mastodon verification hint on the social media editor" do
    test "explains rel=me and shows the member's own profile URL", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      body = conn |> get(~p"/settings/social_media_accounts") |> html_response(200)

      assert body =~ "Mastodon"
      assert body =~ "verified"
      assert body =~ url(~p"/#{user}")
    end
  end

  describe "the Fediverse opt-in flag" do
    test "defaults to off", %{conn: _conn} do
      user = insert(:activated_user)

      refute user.fediverse_followers?
    end

    test "shows on the privacy settings page, marked as upcoming", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      body = conn |> get(~p"/settings/privacy") |> html_response(200)

      assert body =~ "Fediverse"
      assert body =~ ~s(name="user[fediverse_followers?]")
      # The honest label: the switch records the choice, the feature ships later.
      assert body =~ "will ship later"
    end

    test "the privacy form persists the opt-in", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = put(conn, ~p"/settings/privacy", %{"user" => %{"fediverse_followers?" => "true"}})

      assert redirected_to(conn) == ~p"/settings/privacy"
      assert Vutuv.Accounts.get_user(user.id).fediverse_followers?
    end

    # The settings-hub restructure moved the update routes to the
    # user-agnostic /settings URLs, but the privacy/notifications templates
    # kept posting to the retired /:slug/settings twins — every Save button on
    # those two pages 404ed in a real browser while the ConnTest suite (which
    # PUTs the routable URL directly) stayed green. Pin the rendered actions.
    test "the privacy and notifications forms post to URLs that still route",
         %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      privacy = conn |> get(~p"/settings/privacy") |> html_response(200)
      assert privacy =~ ~s(action="#{~p"/settings/privacy"}")
      refute privacy =~ ~s(action="/#{user.username}/settings/privacy")

      notifications =
        conn |> recycle() |> get(~p"/settings/notifications") |> html_response(200)

      assert notifications =~ ~s(action="#{~p"/settings/notifications"}")
      refute notifications =~ ~s(action="/#{user.username}/settings/notifications")
    end
  end

  describe "GDPR export" do
    test "includes the fediverse opt-in flag" do
      user = insert(:activated_user)

      export = Vutuv.Export.build(user)

      assert export.profile.fediverse_followers == false
    end
  end
end
