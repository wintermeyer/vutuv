defmodule VutuvWeb.AdBookingLiveTest do
  @moduledoc """
  The three-step booking wizard at `/system/ads/new`.

  What each test is about is the step it pins: the ad drawn from what is being
  typed, a calendar that works in the block being bought, and a booking that is
  the same purchase `Vutuv.Ads` makes from anywhere else.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Vutuv.MailboxHelpers

  alias Vutuv.Ads
  alias Vutuv.Ads.Ad
  alias Vutuv.Repo

  @text %{
    "title" => "Acme sucht Leute",
    "body" => "Elixir in Mainz.",
    "url" => "https://acme.example"
  }

  @billing %{
    "billing_name" => "Acme GmbH",
    "billing_street" => "Musterstraße 1",
    "billing_zip_code" => "10115",
    "billing_city" => "Berlin",
    "billing_country" => "Deutschland"
  }

  # The wizard, and the signed-in conn it was reached with - a second visit in
  # the same test has to carry that session, not the bare conn.
  defp logged_in(conn) do
    {conn, user} = create_and_login_user(conn)
    {:ok, view, _html} = live(conn, ~p"/system/ads/new")
    {view, user, conn}
  end

  # Step 1 -> step 2 -> a picked day, which is where most tests start.
  defp at_period(view, days \\ 1) do
    render_submit(element(view, "#ad-text-form"), %{"ad" => @text})
    if days != 1, do: render_click(element(view, "button[phx-value-days='#{days}']"))
    view
  end

  defp pick(view, %Date{} = day) do
    render_click(element(view, "button[phx-value-day='#{Date.to_iso8601(day)}']"))
    view
  end

  describe "who may book" do
    test "a visitor is sent away", %{conn: conn} do
      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/system/ads/new")
      assert to == "/login"
    end
  end

  describe "step 1: writing the ad" do
    test "the card is drawn from what is being typed, before it is valid", %{conn: conn} do
      {view, _user, _conn} = logged_in(conn)

      html =
        render_change(element(view, "#ad-text-form"), %{
          "ad" => %{"title" => "Halb getippt", "body" => "", "url" => ""}
        })

      # The preview is the real card component, so what a buyer checks here is
      # what a profile will draw.
      assert html =~ "Halb getippt"
      assert has_element?(view, "#wizard-preview")
    end

    test "an incomplete ad does not reach the calendar", %{conn: conn} do
      {view, _user, _conn} = logged_in(conn)

      render_submit(element(view, "#ad-text-form"), %{"ad" => %{@text | "url" => "not a url"}})

      assert has_element?(view, "#ad-text-form")
      refute has_element?(view, "#ad-calendar")
    end

    test "a finished ad opens the calendar", %{conn: conn} do
      {view, _user, _conn} = logged_in(conn)
      at_period(view)

      assert has_element?(view, "#ad-calendar")
    end
  end

  describe "saved ads" do
    test "an ad can be saved, used again and forgotten", %{conn: conn} do
      {view, user, conn} = logged_in(conn)

      render_change(element(view, "#ad-text-form"), %{"ad" => @text})
      render_click(element(view, "button[phx-click='save-text']"))

      assert [creative] = Ads.list_creatives(user)
      assert creative.title == @text["title"]

      # A fresh wizard offers it, and picking it fills the form in.
      {:ok, second, _html} = live(conn, ~p"/system/ads/new")
      html = render_click(element(second, "button[phx-click='use-creative']"))
      assert html =~ @text["title"]

      render_click(element(second, "button[phx-click='forget-creative']"))
      assert Ads.list_creatives(user) == []
    end

    test "saving does not tie a booking to the saved copy", %{conn: conn} do
      {view, user, conn} = logged_in(conn)

      render_change(element(view, "#ad-text-form"), %{"ad" => @text})
      render_click(element(view, "button[phx-click='save-text']"))
      assert [creative] = Ads.list_creatives(user)

      book(view, Ads.next_available_day())
      assert %Ad{} = ad = Repo.one(Ad)

      # Editing the saved ad afterwards must not reach into what was booked -
      # the booking carries its own copy, which is what an invoice was written
      # against.
      {:ok, _} = Ads.save_creative(user, %{@text | "title" => "Ganz anders"}, creative)
      assert Repo.get!(Ad, ad.id).title == @text["title"]
    end
  end

  describe "step 2: the calendar" do
    test "it shows this month and the next three", %{conn: conn} do
      {view, _user, _conn} = logged_in(conn)
      at_period(view)

      assert length(elements(render(view), "[data-calendar-month]")) == 4
    end

    test "a booked day cannot be picked", %{conn: conn} do
      taken = Ads.next_available_day()
      insert(:ad, day: taken)
      {view, _user, _conn} = logged_in(conn)
      at_period(view)

      refute has_element?(view, "button[phx-value-day='#{Date.to_iso8601(taken)}']")
    end

    test "with a week chosen, only days with seven free behind them may start it", %{conn: conn} do
      first = Ads.next_available_day()
      # A single taken day four days out blocks every start that would span it.
      insert(:ad, day: Date.add(first, 4))
      {view, _user, _conn} = logged_in(conn)
      at_period(view, 7)

      refute has_element?(view, "button[phx-value-day='#{Date.to_iso8601(first)}']")
      assert has_element?(view, "button[phx-value-day='#{Date.to_iso8601(Date.add(first, 5))}']")
    end

    test "picking a start marks the whole stretch, not one day", %{conn: conn} do
      first = Ads.next_available_day()
      {view, _user, _conn} = logged_in(conn)

      view |> at_period(7) |> pick(first)
      html = render(view)

      for offset <- 0..6 do
        day = Date.to_iso8601(Date.add(first, offset))
        assert html =~ ~s(data-day="#{day}")
        assert length(elements(html, ~s([data-day="#{day}"][aria-pressed="true"]))) == 1
      end

      refute html =~ ~s([data-day="#{Date.to_iso8601(Date.add(first, 7))}" aria-pressed="true")
    end

    test "changing the length drops a start it no longer fits", %{conn: conn} do
      first = Ads.next_available_day()
      insert(:ad, day: Date.add(first, 3))
      {view, _user, _conn} = logged_in(conn)

      view |> at_period(1) |> pick(first)
      assert render(view) =~ "aria-pressed=\"true\""

      # Seven days no longer fit behind that start, so the selection goes
      # rather than quietly booking a stretch nobody picked.
      render_click(element(view, "button[phx-value-days='7']"))
      refute has_element?(view, "[data-day][aria-pressed='true']")
    end

    test "the calendar cannot be skipped", %{conn: conn} do
      {view, _user, _conn} = logged_in(conn)
      at_period(view)

      # The way on is not merely ignored, it is not offered: nothing here says
      # which days were picked, so a press that did nothing would read as broken.
      assert has_element?(view, "button[phx-click='to-billing'][disabled]")
      refute has_element?(view, "#ad-billing-form")
    end
  end

  describe "step 3: booking" do
    test "a week is booked as one purchase and mailed once", %{conn: conn} do
      first = Ads.next_available_day()
      {view, user, conn} = logged_in(conn)

      view |> at_period(7) |> pick(first)
      render_click(element(view, "button[phx-click='to-billing']"))

      assert {:error, {:live_redirect, %{to: to}}} =
               render_submit(element(view, "#ad-billing-form"), %{"ad" => @billing})

      assert to == ~p"/system/ads/bookings"

      rows = Repo.all(Ad)
      assert length(rows) == 7
      assert [group] = rows |> Enum.map(& &1.group_id) |> Enum.uniq()
      assert is_binary(group)
      assert Enum.sum(Enum.map(rows, & &1.price_cents)) == 200_000
      assert Enum.all?(rows, &(&1.user_id == user.id))
      assert Enum.all?(rows, &(&1.title == @text["title"]))

      # One purchase, so the operator and the booker hear once each.
      assert length(flush_emails()) == 2
    end

    test "a day taken while the invoice was typed sends them back to the calendar", %{conn: conn} do
      first = Ads.next_available_day()
      {view, _user, _conn} = logged_in(conn)

      view |> at_period(1) |> pick(first)
      render_click(element(view, "button[phx-click='to-billing']"))

      # Somebody else books it in the meantime.
      insert(:ad, day: first)

      html = render_submit(element(view, "#ad-billing-form"), %{"ad" => @billing})

      assert html =~ "id=\"booking-error\""
      assert has_element?(view, "#ad-calendar")
      # And the calendar now shows it as taken, so the same day cannot be
      # picked a second time.
      refute has_element?(view, "button[phx-value-day='#{Date.to_iso8601(first)}']")
    end

    test "a missing invoice field keeps them on the last step", %{conn: conn} do
      {view, _user, _conn} = logged_in(conn)

      view |> at_period(1) |> pick(Ads.next_available_day())
      render_click(element(view, "button[phx-click='to-billing']"))

      render_submit(element(view, "#ad-billing-form"), %{
        "ad" => Map.delete(@billing, "billing_street")
      })

      assert has_element?(view, "#ad-billing-form")
      assert Repo.aggregate(Ad, :count) == 0
      assert flush_emails() == []
    end

    test "a second booking meets the invoice address already filled in", %{conn: conn} do
      {view, _user, conn} = logged_in(conn)
      book(view, Ads.next_available_day())

      {:ok, second, _html} = live(conn, ~p"/system/ads/new")
      second |> at_period(1) |> pick(Date.add(Ads.next_available_day(), 1))
      html = render_click(element(second, "button[phx-click='to-billing']"))

      assert html =~ "Musterstraße 1"
    end
  end

  # Text, day, invoice, confirm - the whole wizard, for the tests that need a
  # booking to exist rather than to watch one being made.
  defp book(view, day) do
    view |> at_period(1) |> pick(day)
    render_click(element(view, "button[phx-click='to-billing']"))
    render_submit(element(view, "#ad-billing-form"), %{"ad" => @billing})
    flush_emails()
  end
end
