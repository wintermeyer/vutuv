defmodule VutuvWeb.AdControllerTest do
  use VutuvWeb.ConnCase

  alias Vutuv.Ads
  alias Vutuv.Repo

  @booking_params %{
    "day" => Date.to_iso8601(Date.add(Ads.today(), 14)),
    "content" => "**Acme GmbH** sucht Elixir-Entwickler.",
    "billing_name" => "Acme GmbH",
    "billing_company" => "",
    "billing_street" => "Musterstraße 1",
    "billing_zip_code" => "10115",
    "billing_city" => "Berlin",
    "billing_country" => "Deutschland",
    "vat_id" => "DE123456789"
  }

  describe "index (the public offer page)" do
    test "shows price and conditions to anonymous visitors", %{conn: conn} do
      html = conn |> get(~p"/ads") |> html_response(200)

      assert html =~ "1,250"
      assert html =~ "2048"
      assert html =~ ~p"/ads/new"
    end

    test "every public fact also appears in the agent formats (no drift)", %{conn: conn} do
      next_day = Date.to_iso8601(Ads.next_available_day())
      window_end = Date.to_iso8601(Ads.last_bookable_day())

      rendered = %{
        html: get(conn, ~p"/ads") |> html_response(200),
        md: get(build_conn(), "/ads.md").resp_body,
        txt: get(build_conn(), "/ads.txt").resp_body,
        json: get(build_conn(), "/ads.json").resp_body
      }

      for {format, body} <- rendered,
          fact <- ["1,250", "2048", "family-friendly", next_day, window_end] do
        assert body =~ fact,
               "#{inspect(fact)} is missing from the #{format} version — " <>
                 "HTML page and agent doc have drifted apart (see VutuvWeb.AgentDocs)"
      end
    end
  end

  describe "new" do
    test "requires login", %{conn: conn} do
      conn = get(conn, ~p"/ads/new")
      assert redirected_to(conn) == "/"
    end

    test "renders the booking form for a logged-in member", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/ads/new") |> html_response(200)

      assert html =~ "id=\"ad-form\""
      assert html =~ "billing_name"
      assert html =~ "1,250"
    end

    test "the availability calendar offers free days and marks booked ones", %{conn: conn} do
      first = Ads.next_available_day()
      booked = insert(:ad, day: Date.add(first, 1))
      {conn, _user} = create_and_login_user(conn)

      html = conn |> get(~p"/ads/new") |> html_response(200)

      # A free day is a selectable radio; a booked day is not offered.
      assert html =~ ~s(value="#{first}")
      refute html =~ ~s(value="#{booked.day}")
      # The grid spans the window: two month headings, booked-day marker.
      assert html =~ "data-calendar-day=\"#{booked.day}\""
      assert length(Regex.scan(~r/data-calendar-month/, html)) == 2
    end

    test "a day beyond the booking window re-renders with the error", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      beyond = Date.add(Ads.last_bookable_day(), 1)

      conn =
        post(conn, ~p"/ads", %{"ad" => Map.put(@booking_params, "day", Date.to_iso8601(beyond))})

      assert html_response(conn, 422) =~ "is outside the booking window"
    end
  end

  describe "preview (the check before buying)" do
    test "requires login", %{conn: conn} do
      conn = post(conn, ~p"/ads/preview", %{"ad" => @booking_params})
      assert redirected_to(conn) == "/"
    end

    test "tolerates a tampered list-valued param without a 500", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      # A crafted non-scalar value must not crash the hidden-input stringify.
      params = Map.put(@booking_params, "billing_company", ["x", "y"])

      conn = post(conn, ~p"/ads/preview", %{"ad" => params})
      assert conn.status in [200, 422]
    end

    test "shows the ad exactly as the banner will render it, plus the order summary", %{
      conn: conn
    } do
      {conn, _user} = create_and_login_user(conn)
      conn = post(conn, ~p"/ads/preview", %{"ad" => @booking_params})
      html = html_response(conn, 200)

      # The rendered ad with its mandatory label...
      assert html =~ "<strong>Acme GmbH</strong>"
      assert html =~ ">Ad</span>"
      # ...but none of the live-banner hooks: no hourly-cap marker, no
      # two-minute auto-hide, no dismiss control (the preview must not
      # vanish, burn the slot, or set the dismissed-for-today cookie).
      refute html =~ "vutuv-ad"
      refute html =~ "data-ad-banner"
      refute html =~ "data-ad-close"

      # The order summary and both ways forward.
      assert html =~ @booking_params["day"]
      assert html =~ "1,250"
      assert html =~ ~s(action="/ads") or html =~ ~s(action="#{~p"/ads"}")
      assert html =~ ~s(formaction="/ads/new")
      # The params ride along as hidden fields for the confirm POST.
      assert html =~ ~s(name="ad[content]")
      assert html =~ ~s(name="ad[billing_name]")
      # Nothing is booked yet.
      assert Repo.aggregate(Ads.Ad, :count) == 0
      assert flush_emails() == []
    end

    test "invalid input goes back to the form with errors", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      conn =
        post(conn, ~p"/ads/preview", %{"ad" => Map.put(@booking_params, "billing_name", "")})

      html = html_response(conn, 422)
      assert html =~ "id=\"ad-form\""
      refute html =~ ~s(formaction="/ads/new")
    end

    test "an already booked day is caught at preview time", %{conn: conn} do
      insert(:ad, day: Date.from_iso8601!(@booking_params["day"]))
      {conn, _user} = create_and_login_user(conn)

      conn = post(conn, ~p"/ads/preview", %{"ad" => @booking_params})
      html = html_response(conn, 422)

      assert html =~ "id=\"ad-form\""
      assert html =~ "has already been booked"
    end

    test "the edit round-trip keeps the entered values", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      conn = post(conn, ~p"/ads/new", %{"ad" => @booking_params})
      html = html_response(conn, 200)

      assert html =~ "id=\"ad-form\""
      assert html =~ @booking_params["content"]
      assert html =~ "Acme GmbH"
    end
  end

  describe "bookings (the member dashboard)" do
    test "requires login", %{conn: conn} do
      conn = get(conn, ~p"/ads/bookings")
      assert redirected_to(conn) == "/"
    end

    test "lists only my bookings, with their approval status", %{conn: conn} do
      insert(:ad, day: Date.add(Ads.today(), 30), content: "Somebody else's ad")
      {conn, user} = create_and_login_user(conn)

      pending = insert(:ad, approved_at: nil, user: user, content: "**Meine** Anzeige")
      approved = insert(:ad, day: Date.add(Ads.today(), 9), user: user)

      html = conn |> get(~p"/ads/bookings") |> html_response(200)

      assert html =~ "booking-#{pending.id}"
      assert html =~ "booking-#{approved.id}"
      refute html =~ "Somebody else"
      assert html =~ "<strong>Meine</strong>"
      # Both status labels show up (pending review vs. approved).
      assert html =~ "Waiting for approval"
      assert html =~ "Approved"
    end
  end

  describe "create" do
    test "requires login", %{conn: conn} do
      conn = post(conn, ~p"/ads", %{"ad" => @booking_params})
      assert redirected_to(conn) == "/"
      assert Repo.aggregate(Ads.Ad, :count) == 0
    end

    test "books the day and mails the booking (CSRF enforced like a browser)", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)

      conn = get(conn, ~p"/ads/new")
      conn = submit_with_csrf(conn, ~p"/ads", %{"ad" => @booking_params})

      assert redirected_to(conn) == ~p"/ads/bookings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "booked"

      ad = Repo.get_by!(Ads.Ad, day: Date.add(Ads.today(), 14))
      assert ad.user_id == user.id
      assert ad.price_cents == 125_000
      assert ad.vat_id == "DE123456789"
      # Bookings start unapproved: the admin reviews before the ad runs.
      assert ad.approved_at == nil

      assert_received {:email, email}
      assert email.to == [{"Stefan Wintermeyer", "sw@wintermeyer-consulting.de"}]
      assert email.text_body =~ @booking_params["content"]
      assert email.text_body =~ "Acme GmbH"
    end

    test "an already booked day re-renders the form with the error", %{conn: conn} do
      insert(:ad, day: Date.from_iso8601!(@booking_params["day"]))
      {conn, _user} = create_and_login_user(conn)

      conn = post(conn, ~p"/ads", %{"ad" => @booking_params})
      html = html_response(conn, 422)

      assert html =~ "id=\"ad-form\""
      assert html =~ "has already been booked"
      assert flush_emails() == []
    end
  end
end
