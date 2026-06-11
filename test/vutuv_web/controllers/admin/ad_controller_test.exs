defmodule VutuvWeb.Admin.AdControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.Ads
  alias Vutuv.Repo

  describe "authorization" do
    test "non-admins are locked out", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      assert conn |> get(~p"/admin/ads") |> html_response(403)
    end

    test "anonymous visitors are locked out", %{conn: conn} do
      conn = get(conn, ~p"/admin/ads")
      assert redirected_to(conn) == "/"
    end
  end

  describe "index" do
    test "shows the pending ad with its content, billing data and booker", %{conn: conn} do
      booker = insert_activated_user(first_name: "Bea", last_name: "Bucher")

      ad =
        insert(:ad,
          approved_at: nil,
          user: booker,
          content: "**Acme** sucht Leute",
          billing_name: "Acme GmbH"
        )

      {conn, _admin} = create_and_login_admin(conn)
      html = conn |> get(~p"/admin/ads") |> html_response(200)

      assert html =~ "ad-#{ad.id}"
      assert html =~ "<strong>Acme</strong>"
      assert html =~ "Acme GmbH"
      assert html =~ "@#{booker.active_slug}"
      # The pending ad offers the approve action.
      assert html =~ ~p"/admin/ads/#{ad}/approve"
    end

    test "an approved ad shows its approval instead of the button", %{conn: conn} do
      ad = insert(:ad, user: insert_activated_user())

      {conn, _admin} = create_and_login_admin(conn)
      html = conn |> get(~p"/admin/ads") |> html_response(200)

      assert html =~ "ad-#{ad.id}"
      refute html =~ ~p"/admin/ads/#{ad}/approve"
    end
  end

  describe "approve" do
    test "stamps the approval and returns to the dashboard", %{conn: conn} do
      ad = insert(:ad, approved_at: nil, user: insert_activated_user())
      {conn, admin} = create_and_login_admin(conn)

      conn = post(conn, ~p"/admin/ads/#{ad}/approve")
      assert redirected_to(conn) == ~p"/admin/ads"

      reloaded = Repo.get!(Ads.Ad, ad.id)
      assert reloaded.approved_at
      assert reloaded.approved_by_id == admin.id
    end

    test "non-admins cannot approve", %{conn: conn} do
      ad = insert(:ad, approved_at: nil, user: insert_activated_user())
      {conn, _user} = create_and_login_user(conn)

      conn = post(conn, ~p"/admin/ads/#{ad}/approve")
      assert html_response(conn, 403)
      assert Repo.get!(Ads.Ad, ad.id).approved_at == nil
    end
  end
end
