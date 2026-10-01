defmodule VutuvWeb.SettingsBetaTest do
  @moduledoc """
  /settings/beta, where a member (or an admin) switches beta features on and
  off. The hub only lists the page while there is something to switch, the
  form posts through its rendered `action=`, and an admin sees the admin
  features beside the member ones without having any of them on.

  Sync because `Vutuv.BetaHelpers.with_beta_features/1` swaps the registry
  through a global application env.
  """
  use VutuvWeb.ConnCase, async: false

  import Vutuv.BetaHelpers

  alias Vutuv.Accounts

  setup do
    with_beta_features()
  end

  describe "the hub" do
    test "lists the page while there are beta features", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      body = conn |> get(~p"/settings") |> html_response(200)

      assert body =~ ~s(href="/settings/beta")
    end

    test "hides the page when there is nothing to switch on", %{conn: conn} do
      with_beta_features([])
      {conn, _user} = create_and_login_user(conn)

      body = conn |> get(~p"/settings") |> html_response(200)

      refute body =~ ~s(href="/settings/beta")
    end
  end

  describe "the page" do
    test "a member sees the member features, unchecked", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      body = conn |> get(~p"/settings/beta") |> html_response(200)

      assert body =~ "Member feature"
      refute body =~ "Admin feature"
      refute checked?(body, "test_member_feature")
    end

    test "an admin sees both, and neither is on", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)

      body = conn |> get(~p"/settings/beta") |> html_response(200)

      assert body =~ "Member feature"
      assert body =~ "Admin feature"
      refute checked?(body, "test_member_feature")
      refute checked?(body, "test_admin_feature")
    end

    test "saving through the form's own action switches a feature on and off", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      body = conn |> get(~p"/settings/beta") |> html_response(200)
      [_, action] = Regex.run(~r/<form[^>]*action="([^"]+)"[^>]*id="beta-features-form"/, body)

      conn = put(conn, action, %{"beta" => %{"features" => ["", "test_member_feature"]}})
      assert redirected_to(conn) == ~p"/settings/beta"
      assert Accounts.get_user(user.id).beta_features == ["test_member_feature"]

      body = conn |> get(~p"/settings/beta") |> html_response(200)
      assert checked?(body, "test_member_feature")

      # Unticking every box sends only the hidden empty value.
      conn = put(conn, action, %{"beta" => %{"features" => [""]}})
      assert redirected_to(conn) == ~p"/settings/beta"
      assert Accounts.get_user(user.id).beta_features == []
    end
  end

  describe "in German" do
    test "the page and the hub row are translated", %{conn: conn} do
      {conn, _user} = create_and_login_admin(conn)

      hub = conn |> de() |> get(~p"/settings") |> html_response(200)
      assert hub =~ "Beta-Funktionen"
      assert hub =~ "Neue Funktionen ausprobieren, bevor alle sie bekommen"

      body = conn |> de() |> get(~p"/settings/beta") |> html_response(200)
      assert body =~ "Vor allen anderen ausprobieren"
      assert body =~ "In der Beta seit 1. Oktober 2026"
      assert body =~ "Nur für Admins"
    end
  end

  defp de(conn), do: conn |> recycle() |> put_req_header("accept-language", "de-DE,de")

  defp checked?(body, key) do
    elements(body, ~s(input[data-beta-feature="#{key}"][checked])) != []
  end
end
