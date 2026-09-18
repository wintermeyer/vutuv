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

  describe "new" do
    test "requires login", %{conn: conn} do
      conn = get(conn, ~p"/system/ads/new")
      assert redirected_to(conn) == "/"
    end

    test "renders the booking form for a logged-in member", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/system/ads/new") |> html_response(200)

      assert html =~ "id=\"ad-form\""
      assert html =~ "billing_name"
      assert html =~ "350.00 €"
    end

    test "asks for a title, a sentence and a link, with live counters", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      html = conn |> get(~p"/system/ads/new") |> html_response(200)

      assert html =~ ~s(name="ad[title]")
      assert html =~ ~s(name="ad[body]")

      assert html =~
               ~r{<input[^>]*type="url"[^>]*name="ad\[url\]"|<input[^>]*name="ad\[url\]"[^>]*type="url"}

      # Each counter sits in the wrapper app.js wires, beside its field.
      assert length(elements(html, "[data-char-counter] [data-char-count-input]")) == 2
      assert length(elements(html, "[data-char-counter] [data-char-count-readout]")) == 2
      assert html =~ ~s(data-max="30")
      assert html =~ ~s(data-max="90")
      refute html =~ "Markdown"
    end

    test "speaks German to a German reader", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      conn = conn |> recycle() |> put_req_header("accept-language", "de-DE,de")

      html = conn |> get(~p"/system/ads/new") |> html_response(200)
      assert html =~ "Erscheint fett als Link."
      assert html =~ "Ein Satz unter dem Titel, reiner Text."
      assert html =~ "Wohin der Titel führt."

      html =
        build_conn()
        |> put_req_header("accept-language", "de-DE,de")
        |> get(~p"/system/ads")
        |> html_response(200)

      assert html =~
               "Nur Text: ein Titel mit bis zu 30 Zeichen, ein Satz mit bis zu 90 und ein Link"

      assert html =~ "Besucher ohne Konto sehen sie auf jedem Profil, das sie öffnen."
    end

    test "the availability calendar offers free days and marks booked ones", %{conn: conn} do
      first = Ads.next_available_day()
      booked = insert(:ad, day: Date.add(first, 1))
      {conn, _user} = create_and_login_user(conn)

      html = conn |> get(~p"/system/ads/new") |> html_response(200)

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
        post(conn, ~p"/system/ads", %{"ad" => booking_params(beyond)})

      assert html_response(conn, 422) =~ "is outside the booking window"
    end
  end

  describe "preview (the check before buying)" do
    test "requires login", %{conn: conn} do
      conn = post(conn, ~p"/system/ads/preview", %{"ad" => booking_params()})
      assert redirected_to(conn) == "/"
    end

    test "tolerates a tampered list-valued param without a 500", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)
      # A crafted non-scalar value must not crash the hidden-input stringify.
      params = Map.put(booking_params(), "billing_company", ["x", "y"])

      conn = post(conn, ~p"/system/ads/preview", %{"ad" => params})
      assert conn.status in [200, 422]
    end

    test "shows the ad exactly as the banner will render it, plus the order summary", %{
      conn: conn
    } do
      {conn, _user} = create_and_login_user(conn)
      params = booking_params()
      conn = post(conn, ~p"/system/ads/preview", %{"ad" => params})
      html = html_response(conn, 200)

      # The rendered ad with its mandatory label: the title links to the
      # booked page, the address under it is what a reader can check.
      assert html =~
               ~r{<a[^>]*href="https://www.acme.example/jobs"[^>]*>\s*Acme GmbH sucht Leute\s*</a>}

      assert html =~ "Elixir-Entwicklung in Mainz, gern auch remote."
      assert html =~ "acme.example/jobs"
      assert html =~ ">Ad</span>"
      # ...but none of the live card's controls: no auto-hide hook and no
      # dismiss button (the preview must not vanish under the buyer or close
      # their ads for the day).
      refute html =~ "AdSlot"
      refute html =~ "dismiss-ad"

      # The order summary and both ways forward.
      assert html =~ params["day"]
      assert html =~ "350.00 €"
      assert html =~ ~s(action="/system/ads") or html =~ ~s(action="#{~p"/system/ads"}")
      assert html =~ ~s(formaction="/system/ads/new")
      # The params ride along as hidden fields for the confirm POST.
      assert html =~ ~s(name="ad[title]")
      assert html =~ ~s(name="ad[body]")
      assert html =~ ~s(name="ad[url]")
      assert html =~ ~s(name="ad[billing_name]")
      # Nothing is booked yet.
      assert Repo.aggregate(Ads.Ad, :count) == 0
      assert flush_emails() == []
    end

    test "invalid input goes back to the form with errors", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      conn =
        post(conn, ~p"/system/ads/preview", %{
          "ad" => Map.put(booking_params(), "billing_name", "")
        })

      html = html_response(conn, 422)
      assert html =~ "id=\"ad-form\""
      refute html =~ ~s(formaction="/system/ads/new")
    end

    test "an already booked day is caught at preview time", %{conn: conn} do
      params = booking_params()
      insert(:ad, day: Date.from_iso8601!(params["day"]))
      {conn, _user} = create_and_login_user(conn)

      conn = post(conn, ~p"/system/ads/preview", %{"ad" => params})
      html = html_response(conn, 422)

      assert html =~ "id=\"ad-form\""
      assert html =~ "has already been booked"
    end

    test "the edit round-trip keeps the entered values", %{conn: conn} do
      {conn, _user} = create_and_login_user(conn)

      params = booking_params()
      conn = post(conn, ~p"/system/ads/new", %{"ad" => params})
      html = html_response(conn, 200)

      assert html =~ "id=\"ad-form\""
      assert html =~ params["title"]
      assert html =~ params["body"]
      assert html =~ params["url"]
      assert html =~ "Acme GmbH"
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

  describe "create" do
    test "requires login", %{conn: conn} do
      conn = post(conn, ~p"/system/ads", %{"ad" => booking_params()})
      assert redirected_to(conn) == "/"
      assert Repo.aggregate(Ads.Ad, :count) == 0
    end

    test "books the day and mails the booking (CSRF enforced like a browser)", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      params = booking_params()

      conn = get(conn, ~p"/system/ads/new")
      conn = submit_with_csrf(conn, ~p"/system/ads", %{"ad" => params})

      assert redirected_to(conn) == ~p"/system/ads/bookings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "booked"

      # The booked day comes from the SAME params map the form submitted, not
      # from a second Ads.today() read that may sit on the far side of Berlin
      # midnight (the 2026-07-30 CI failure).
      ad = Repo.get_by!(Ads.Ad, day: Date.from_iso8601!(params["day"]))
      assert ad.user_id == user.id
      assert ad.price_cents == 35_000
      assert ad.vat_id == "DE123456789"
      # Bookings start unapproved: the admin reviews before the ad runs.
      assert ad.approved_at == nil

      assert_received {:email, email}
      assert email.to == [{"Stefan Wintermeyer", "sw@wintermeyer-consulting.de"}]
      assert email.text_body =~ params["title"]
      assert email.text_body =~ params["body"]
      assert email.text_body =~ params["url"]
      assert email.text_body =~ "Acme GmbH"
    end

    test "an already booked day re-renders the form with the error", %{conn: conn} do
      params = booking_params()
      insert(:ad, day: Date.from_iso8601!(params["day"]))
      {conn, _user} = create_and_login_user(conn)

      conn = post(conn, ~p"/system/ads", %{"ad" => params})
      html = html_response(conn, 422)

      assert html =~ "id=\"ad-form\""
      assert html =~ "has already been booked"
      assert flush_emails() == []
    end
  end
end
