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
    test "shows the pending ad with its text, link, billing data and booker", %{conn: conn} do
      booker = insert_activated_user(first_name: "Bea", last_name: "Bucher")

      ad =
        insert(:ad,
          approved_at: nil,
          user: booker,
          title: "Acme sucht Leute",
          url: "https://www.acme.example/jobs?ref=vutuv",
          billing_name: "Acme GmbH"
        )

      {conn, _admin} = create_and_login_admin(conn)
      html = conn |> get(~p"/admin/ads") |> html_response(200)

      assert html =~ "ad-#{ad.id}"
      # The ad shows as visitors see it, and its link in full: the address
      # under the title drops the query, the reviewer must not.
      assert html =~ "Acme sucht Leute"
      assert html =~ "https://www.acme.example/jobs?ref=vutuv"
      assert html =~ "Acme GmbH"
      assert html =~ "@#{booker.username}"
      # The pending ad offers the approve action and links its detail page.
      assert html =~ ~p"/admin/ads/#{ad}/approve"
      assert html =~ ~p"/admin/ads/#{ad}"
    end

    test "an approved ad shows its approval instead of the button", %{conn: conn} do
      ad = insert(:ad, user: insert_activated_user())

      {conn, _admin} = create_and_login_admin(conn)
      html = conn |> get(~p"/admin/ads") |> html_response(200)

      assert html =~ "ad-#{ad.id}"
      refute html =~ ~p"/admin/ads/#{ad}/approve"
    end
  end

  describe "reject" do
    test "turns a pending ad down with a reason and tells the booker", %{conn: conn} do
      booker = insert_activated_user()
      insert(:email, user: booker)
      ad = insert(:ad, approved_at: nil, user: booker)
      {conn, _admin} = create_and_login_admin(conn)

      html = conn |> get(~p"/admin/ads") |> html_response(200)
      assert html =~ ~s(action="/admin/ads/#{ad.id}/reject")

      conn = post(conn, ~p"/admin/ads/#{ad}/reject", %{"reason" => "Nicht familienfreundlich."})

      assert redirected_to(conn) == ~p"/admin/ads"
      assert Repo.reload!(ad).rejection_reason == "Nicht familienfreundlich."
      assert_received {:email, mail}
      assert mail.text_body =~ "Nicht familienfreundlich."
    end

    test "without a reason nothing happens", %{conn: conn} do
      ad = insert(:ad, approved_at: nil, user: insert_activated_user())
      {conn, _admin} = create_and_login_admin(conn)

      conn = post(conn, ~p"/admin/ads/#{ad}/reject", %{"reason" => " "})

      assert redirected_to(conn) == ~p"/admin/ads"
      assert Phoenix.Flash.get(conn.assigns.flash, :error)
      assert Repo.reload!(ad).rejected_at == nil
    end
  end

  describe "withdrawn bookings" do
    test "leave the review list for a table of their own", %{conn: conn} do
      rejected =
        insert(:ad,
          approved_at: nil,
          rejected_at: ~U[2026-09-01 10:00:00Z],
          rejection_reason: "Zu laut."
        )

      cancelled =
        insert(:ad, day: Date.add(Ads.today(), 20), cancelled_at: ~U[2026-09-01 10:00:00Z])

      {conn, _admin} = create_and_login_admin(conn)
      html = conn |> get(~p"/admin/ads") |> html_response(200)

      refute html =~ ~s(id="ad-#{rejected.id}")
      refute html =~ ~s(id="ad-#{cancelled.id}")
      assert html =~ ~s(id="withdrawn-ad-#{rejected.id}")
      assert html =~ ~s(id="withdrawn-ad-#{cancelled.id}")
      assert html =~ "Zu laut."
    end
  end

  describe "in German" do
    test "the review controls speak German", %{conn: conn} do
      insert(:ad, approved_at: nil, user: insert_activated_user())
      insert(:ad, day: Ads.today(), user: insert_activated_user())
      {conn, _admin} = create_and_login_admin(conn)

      html =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/admin/ads")
        |> html_response(200)

      assert html =~ ~r/>\s*Ablehnen\s*</
      assert html =~ ~r/>\s*Anzeige stornieren\s*</
      assert html =~ "die buchende Person liest das"
    end
  end

  describe "cancel" do
    test "takes an approved ad off its day; the button is offered only there", %{conn: conn} do
      approved = insert(:ad, user: insert_activated_user())
      pending = insert(:ad, day: Date.add(Ads.today(), 20), approved_at: nil)
      {conn, _admin} = create_and_login_admin(conn)

      html = conn |> get(~p"/admin/ads") |> html_response(200)
      assert html =~ ~s(action="/admin/ads/#{approved.id}/cancel")
      refute html =~ ~s(action="/admin/ads/#{pending.id}/cancel")
      refute html =~ ~s(action="/admin/ads/#{approved.id}/reject")

      conn = post(conn, ~p"/admin/ads/#{approved}/cancel")

      assert redirected_to(conn) == ~p"/admin/ads"
      assert Repo.reload!(approved).cancelled_at
    end
  end

  describe "show" do
    test "renders one ad in full: the card, its link, billing, approval", %{
      conn: conn
    } do
      booker = insert_activated_user(first_name: "Bea", last_name: "Bucher")
      admin_user = insert_activated_user(first_name: "Ada", last_name: "Admin")

      ad =
        insert(:ad,
          user: booker,
          approved_by: admin_user,
          title: "Acme sucht Leute",
          url: "https://www.acme.example/jobs?ref=vutuv",
          billing_name: "Acme GmbH",
          vat_id: "DE123456789",
          day: Ads.today(),
          price_cents: 99_000,
          views_count: 1234,
          clicks_count: 56
        )

      {conn, _admin} = create_and_login_admin(conn)
      html = conn |> get(~p"/admin/ads/#{ad}") |> html_response(200)

      assert html =~ "Acme sucht Leute"
      assert html =~ "https://www.acme.example/jobs?ref=vutuv"
      assert html =~ "Acme GmbH"
      assert html =~ "DE123456789"
      assert html =~ "@#{booker.username}"
      # The price this booking was made at, not today's.
      assert html =~ "990"
      assert html =~ "1,234"
      assert html =~ "56"
      # The approval block names the approving admin.
      assert html =~ "@#{admin_user.username}"
      refute html =~ ~p"/admin/ads/#{ad}/approve"
    end

    test "a pending ad offers the approve action", %{conn: conn} do
      ad = insert(:ad, approved_at: nil, user: insert_activated_user())
      {conn, _admin} = create_and_login_admin(conn)

      html = conn |> get(~p"/admin/ads/#{ad}") |> html_response(200)
      assert html =~ ~p"/admin/ads/#{ad}/approve"
    end

    test "only admins can see it", %{conn: conn} do
      ad = insert(:ad, user: insert_activated_user())

      anonymous = get(conn, ~p"/admin/ads/#{ad}")
      assert redirected_to(anonymous) == "/"

      {conn, _user} = create_and_login_user(conn)
      assert conn |> get(~p"/admin/ads/#{ad}") |> html_response(403)
    end

    test "404s on an unknown or malformed id", %{conn: conn} do
      {conn, _admin} = create_and_login_admin(conn)

      assert conn |> get(~p"/admin/ads/#{Vutuv.UUIDv7.generate()}") |> html_response(404)
      assert conn |> get(~p"/admin/ads/not-a-uuid") |> html_response(404)
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
