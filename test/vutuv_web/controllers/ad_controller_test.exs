defmodule VutuvWeb.AdControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.Ads
  alias Vutuv.Repo

  # A function, deliberately NOT a module attribute: an attribute's day would
  # be minted when the file compiles, while assertions read Ads.today() at run
  # time — across Berlin midnight (22:00 UTC in summer) the two disagree and
  # the suite fails only in that nightly window (caught on CI 2026-07-30
  # 22:01 UTC). Each test binds the map ONCE and derives every day it asserts
  # from that same map, so one clock read serves the whole test.
  defp booking_params(day \\ Date.add(Ads.today(), 14)) do
    %{
      "day" => Date.to_iso8601(day),
      "title" => "Acme GmbH sucht Leute",
      "body" => "Elixir-Entwicklung in Mainz, gern auch remote.",
      "url" => "https://www.acme.example/jobs",
      "billing_name" => "Acme GmbH",
      "billing_company" => "",
      "billing_street" => "Musterstraße 1",
      "billing_zip_code" => "10115",
      "billing_city" => "Berlin",
      "billing_country" => "Deutschland",
      "vat_id" => "DE123456789"
    }
  end

  describe "index (the public offer page)" do
    test "shows price and conditions to anonymous visitors", %{conn: conn} do
      html = conn |> get(~p"/system/ads") |> html_response(200)

      assert html =~ "350.00 €"
      assert html =~ "a title of up to 30 characters"
      assert html =~ ~p"/system/ads/new"
    end

    test "lives under /system/, and the root word /ads serves nothing", %{conn: conn} do
      assert conn |> get("/ads") |> html_response(404)
      assert get(build_conn(), "/ads/new").status == 404
    end

    test "every public fact also appears in the agent formats (no drift)", %{conn: conn} do
      next_day = Date.to_iso8601(Ads.next_available_day())
      window_end = Date.to_iso8601(Ads.last_bookable_day())

      rendered = %{
        html: get(conn, ~p"/system/ads") |> html_response(200),
        md: get(build_conn(), "/system/ads.md").resp_body,
        txt: get(build_conn(), "/system/ads.txt").resp_body,
        json: get(build_conn(), "/system/ads.json").resp_body
      }

      # The community-guidelines link the HTML page shows and JSON/XML carry
      # (community_guidelines_url) must also reach Markdown and text — those two
      # used to silently drop it.
      for {format, body} <- rendered,
          fact <- [
            "350.00 €",
            "a title of up to 30 characters",
            "family-friendly",
            "/community",
            next_day,
            window_end
          ] do
        assert body =~ fact,
               "#{inspect(fact)} is missing from the #{format} version — " <>
                 "HTML page and agent doc have drifted apart (see VutuvWeb.AgentDocs)"
      end
    end
  end

  describe "bookings (the member dashboard)" do
    test "requires login", %{conn: conn} do
      conn = get(conn, ~p"/system/ads/bookings")
      assert redirected_to(conn) == "/"
    end

    test "lists only my bookings, with their approval status", %{conn: conn} do
      insert(:ad, day: Date.add(Ads.today(), 30), title: "Somebody else's ad")
      {conn, user} = create_and_login_user(conn)

      pending = insert(:ad, approved_at: nil, user: user, title: "Meine Anzeige")
      approved = insert(:ad, day: Date.add(Ads.today(), 9), user: user)

      html = conn |> get(~p"/system/ads/bookings") |> html_response(200)

      assert html =~ "booking-#{pending.id}"
      assert html =~ "booking-#{approved.id}"
      refute html =~ "Somebody else"
      assert html =~ "Meine Anzeige"
      # Both status labels show up (pending review vs. approved).
      assert html =~ "Waiting for approval"
      assert html =~ "Approved"
    end
  end

  describe "bookings, what each one shows" do
    test "a pending booking can be cancelled from here, an approved one cannot", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      pending = insert(:ad, approved_at: nil, user: user)
      approved = insert(:ad, day: Date.add(Ads.today(), 9), user: user)

      html = conn |> get(~p"/system/ads/bookings") |> html_response(200)

      assert html =~ ~s(action="/system/ads/#{pending.id}/cancel")
      refute html =~ ~s(action="/system/ads/#{approved.id}/cancel")
    end

    test "the day in the reader's way, the price paid, and the numbers once it ran", %{
      conn: conn
    } do
      {conn, user} = create_and_login_user(conn)

      ran =
        insert(:ad,
          day: Ads.today(),
          user: user,
          price_cents: 99_000,
          views_count: 1234,
          clicks_count: 56
        )

      html =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/system/ads/bookings")
        |> html_response(200)

      assert html =~ Calendar.strftime(ran.day, "%d.%m.%Y")
      refute html =~ Date.to_iso8601(ran.day)
      assert html =~ "990,00 €"
      refute html =~ "350,00 € pro Tag"
      assert html =~ "1.234"
      assert html =~ "56"
    end

    test "speaks German to a German booker", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      insert(:ad, approved_at: nil, user: user)

      insert(:ad,
        day: Date.add(Ads.today(), 10),
        user: user,
        cancelled_at: ~U[2026-09-01 10:00:00Z]
      )

      insert(:ad,
        day: Date.add(Ads.today(), 11),
        approved_at: nil,
        user: user,
        rejected_at: ~U[2026-09-01 10:00:00Z],
        rejection_reason: "Zu laut."
      )

      html =
        conn
        |> recycle()
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/system/ads/bookings")
        |> html_response(200)

      assert html =~ "Buchung stornieren"
      assert html =~ "Bis dahin können Sie die Buchung kostenlos stornieren."
      assert html =~ ~r/>\s*Storniert\s*</
      assert html =~ "Nicht freigeschaltet: Zu laut."
    end

    test "a rejected booking says why", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      insert(:ad,
        approved_at: nil,
        user: user,
        rejected_at: ~U[2026-09-01 10:00:00Z],
        rejection_reason: "Der Link führt ins Leere."
      )

      html = conn |> get(~p"/system/ads/bookings") |> html_response(200)
      assert html =~ "Rejected"
      assert html =~ "Der Link führt ins Leere."
    end
  end

  describe "taking an approved ad off the site" do
    setup %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      first = Ads.next_available_day()

      {:ok, ad} =
        Ads.book_ad(user, %{booking_params() | "day" => Date.to_iso8601(first)}, 1)

      {:ok, _} = Ads.approve_ad(ad, insert(:user))
      Repo.update_all(Ads.Ad, set: [day: Ads.today()])
      flush_emails()

      %{conn: conn, ad: Repo.get!(Ads.Ad, ad.id)}
    end

    test "the bookings page offers it in a modal that says there is no refund", %{conn: conn} do
      html = conn |> get(~p"/system/ads/bookings") |> html_response(200)

      # A <dialog>, not a `data-confirm` one-liner: what has to be read is the
      # price of the act, and a native confirm gives one unstyled line.
      assert html =~ "<dialog"
      assert html =~ "no money back"
      assert html =~ "the invoice stands"
      assert html =~ "/withdraw"
    end

    test "it takes the ad off and says the invoice stands", %{conn: conn, ad: ad} do
      conn = post(conn, ~p"/system/ads/#{ad}/withdraw")

      assert redirected_to(conn) == ~p"/system/ads/bookings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "invoice stands"
      assert Repo.get!(Ads.Ad, ad.id).cancelled_at != nil
      assert Ads.current_banner() == :house
    end

    test "somebody else's booking is a 404", %{ad: ad} do
      {other_conn, _other} =
        build_conn() |> Plug.Test.init_test_session(%{}) |> create_and_login_user()

      assert other_conn |> post(~p"/system/ads/#{ad}/withdraw") |> html_response(404)
      assert Repo.get!(Ads.Ad, ad.id).cancelled_at == nil
    end
  end

  describe "cancel" do
    test "requires login", %{conn: conn} do
      ad = insert(:ad, approved_at: nil)
      conn = post(conn, ~p"/system/ads/#{ad}/cancel")
      assert redirected_to(conn) == "/"
      assert Repo.reload!(ad).cancelled_at == nil
    end

    test "the booker cancels a pending booking (CSRF enforced like a browser)", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      ad = insert(:ad, approved_at: nil, user: user)

      conn = get(conn, ~p"/system/ads/bookings")
      conn = submit_with_csrf(conn, ~p"/system/ads/#{ad}/cancel", %{})

      assert redirected_to(conn) == ~p"/system/ads/bookings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "cancelled"
      assert Repo.reload!(ad).cancelled_at
      assert_received {:email, notice}
      assert notice.subject =~ "Stornierung"
    end

    test "not an approved booking, and not somebody else's", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      approved = insert(:ad, user: user)
      foreign = insert(:ad, day: Date.add(Ads.today(), 20), approved_at: nil)

      conn = post(conn, ~p"/system/ads/#{approved}/cancel")
      assert redirected_to(conn) == ~p"/system/ads/bookings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error)
      assert Repo.reload!(approved).cancelled_at == nil

      assert conn |> post(~p"/system/ads/#{foreign}/cancel") |> html_response(404)

      assert Repo.reload!(foreign).cancelled_at == nil
    end
  end
end
