defmodule Vutuv.AdsTest do
  use Vutuv.DataCase, async: true
  import Vutuv.MailboxHelpers

  alias Vutuv.Ads
  alias Vutuv.Ads.Ad
  alias Vutuv.Ads.Sighting

  @valid_attrs %{
    "day" => Date.to_iso8601(Date.add(Ads.today(), 7)),
    "content" => "**Acme GmbH** sucht Elixir-Entwickler. https://acme.example",
    "billing_name" => "Acme GmbH",
    "billing_street" => "Musterstraße 1",
    "billing_zip_code" => "10115",
    "billing_city" => "Berlin",
    "billing_country" => "Deutschland"
  }

  defp booker do
    insert_activated_user(first_name: "Bea", last_name: "Bucher")
  end

  describe "book_ad/2" do
    test "books the day, stamps the fixed price and mails the booking" do
      user = booker()

      assert {:ok, %Ad{} = ad} = Ads.book_ad(user, @valid_attrs)
      assert ad.user_id == user.id
      assert ad.price_cents == 125_000
      assert ad.day == Date.add(Ads.today(), 7)

      assert_received {:email, email}
      assert email.to == [{"Stefan Wintermeyer", "sw@wintermeyer-consulting.de"}]
      # The mail carries everything the manual invoice needs: billing data,
      # the booked day and the full ad text.
      assert email.text_body =~ "Acme GmbH"
      assert email.text_body =~ "Musterstraße 1"
      assert email.text_body =~ "10115"
      assert email.text_body =~ "1.250,00"
      assert email.text_body =~ @valid_attrs["content"]
      assert email.text_body =~ "@#{user.username}"
      assert email.subject =~ Calendar.strftime(ad.day, "%d.%m.%Y")
    end

    test "a day can only be booked once" do
      assert {:ok, _ad} = Ads.book_ad(booker(), @valid_attrs)
      flush_emails()

      assert {:error, changeset} = Ads.book_ad(booker(), @valid_attrs)
      assert "has already been booked" in errors_on(changeset).day
      assert flush_emails() == []
    end

    test "rejects days that leave no time for the approval review" do
      # Earliest bookable day is three days out (the admin reviews first).
      for offset <- [-1, 0, 1, 2] do
        attrs = Map.put(@valid_attrs, "day", Date.to_iso8601(Date.add(Ads.today(), offset)))
        assert {:error, changeset} = Ads.book_ad(booker(), attrs)
        assert "must be booked at least three days ahead" in errors_on(changeset).day
      end

      attrs = Map.put(@valid_attrs, "day", Date.to_iso8601(Date.add(Ads.today(), 3)))
      assert {:ok, _ad} = Ads.book_ad(booker(), attrs)
      assert flush_emails() != []
    end

    test "rejects a billing field longer than the varchar(255) column" do
      attrs = Map.put(@valid_attrs, "billing_company", String.duplicate("a", 256))

      assert {:error, changeset} = Ads.book_ad(booker(), attrs)
      assert Enum.any?(errors_on(changeset).billing_company, &(&1 =~ "at most 255"))
      assert flush_emails() == []
    end

    test "rejects days beyond the booking window" do
      beyond = Date.add(Ads.last_bookable_day(), 1)
      attrs = Map.put(@valid_attrs, "day", Date.to_iso8601(beyond))

      assert {:error, changeset} = Ads.book_ad(booker(), attrs)
      assert "is outside the booking window" in errors_on(changeset).day

      attrs = Map.put(@valid_attrs, "day", Date.to_iso8601(Ads.last_bookable_day()))
      assert {:ok, _ad} = Ads.book_ad(booker(), attrs)
      flush_emails()
    end

    test "rejects ad text longer than 2048 characters" do
      attrs = Map.put(@valid_attrs, "content", String.duplicate("a", 2049))
      assert {:error, changeset} = Ads.book_ad(booker(), attrs)
      assert %{content: [_]} = errors_on(changeset)
    end

    test "requires the billing address" do
      attrs = Map.drop(@valid_attrs, ["billing_name", "billing_street"])
      assert {:error, changeset} = Ads.book_ad(booker(), attrs)
      assert %{billing_name: [_], billing_street: [_]} = errors_on(changeset)
    end
  end

  describe "approve_ad/2" do
    test "stamps the approval and the approving admin" do
      {:ok, ad} = Ads.book_ad(booker(), @valid_attrs)
      flush_emails()
      admin = insert_activated_user(first_name: "Ada", last_name: "Admin")

      assert ad.approved_at == nil
      assert {:ok, approved} = Ads.approve_ad(ad, admin)
      assert approved.approved_at
      assert approved.approved_by_id == admin.id
    end

    test "is idempotent: a second approval keeps the first stamp" do
      {:ok, ad} = Ads.book_ad(booker(), @valid_attrs)
      flush_emails()
      admin = insert_activated_user()
      other_admin = insert_activated_user()

      {:ok, approved} = Ads.approve_ad(ad, admin)
      {:ok, still} = Ads.approve_ad(approved, other_admin)
      assert still.approved_at == approved.approved_at
      assert still.approved_by_id == admin.id
    end
  end

  describe "current_banner/0" do
    test "is the house ad while no ad is booked for today" do
      assert Ads.current_banner() == :house
    end

    test "is the booked ad on its day once approved" do
      ad = insert(:ad, day: Ads.today())
      assert {:ad, %Ad{id: id}} = Ads.current_banner()
      assert id == ad.id
    end

    test "an unapproved ad never runs: the house ad serves instead" do
      insert(:ad, day: Ads.today(), approved_at: nil)
      assert Ads.current_banner() == :house
    end
  end

  describe "next_available_day/0" do
    test "starts three days out (approval lead time) and skips booked days" do
      first = Date.add(Ads.today(), 3)
      assert Ads.next_available_day() == first

      insert(:ad, day: first)
      assert Ads.next_available_day() == Date.add(first, 1)
    end
  end

  describe "the booking window" do
    test "ends with next month (the calendar's last grid)" do
      expected = Ads.today() |> Date.shift(month: 1) |> Date.end_of_month()
      assert Ads.last_bookable_day() == expected
    end

    test "booked_days/0 is the set of taken days within the window" do
      assert Ads.booked_days() == MapSet.new()

      ad = insert(:ad)
      assert Ads.booked_days() == MapSet.new([ad.day])
    end
  end

  describe "eligible?/3" do
    test "nothing seen and nothing closed: an ad may show" do
      assert Ads.eligible?(nil, nil)
    end

    test "an ad seen within the hour holds the next one back, an older one does not" do
      now = ~U[2026-09-17 10:00:00Z]

      refute Ads.eligible?(~U[2026-09-17 09:00:01Z], nil, now)
      assert Ads.eligible?(~U[2026-09-17 09:00:00Z], nil, now)
    end

    test "a day with a closed ad holds every ad back until Berlin midnight" do
      refute Ads.eligible?(nil, Ads.today())
      assert Ads.eligible?(nil, Date.add(Ads.today(), -1))
    end
  end

  describe "dismiss_today/1" do
    test "stamps today's Berlin date on the member" do
      user = insert_activated_user()

      Ads.dismiss_today(user)

      assert Repo.reload!(user).ads_dismissed_on == Ads.today()
    end
  end

  describe "record_sighting/3" do
    test "a booked ad stamps the member's hour and is kept for their history" do
      user = insert_activated_user()
      ad = insert(:ad, day: Ads.today())
      now = ~U[2026-09-17 08:02:00Z]

      assert Ads.record_sighting(user, {:ad, ad}, now) == :ok

      assert Repo.reload!(user).ad_seen_at == now
      assert [sighting] = Repo.all(Sighting)
      assert {sighting.user_id, sighting.ad_id} == {user.id, ad.id}
      assert {sighting.first_seen_at, sighting.last_seen_at, sighting.times_seen} == {now, now, 1}
    end

    test "seeing the same ad again counts up on the one row" do
      user = insert_activated_user()
      ad = insert(:ad, day: Ads.today())

      Ads.record_sighting(user, {:ad, ad}, ~U[2026-09-17 08:02:00Z])
      Ads.record_sighting(user, {:ad, ad}, ~U[2026-09-17 10:31:00Z])

      assert [sighting] = Repo.all(Sighting)
      assert sighting.first_seen_at == ~U[2026-09-17 08:02:00Z]
      assert sighting.last_seen_at == ~U[2026-09-17 10:31:00Z]
      assert sighting.times_seen == 2
    end

    test "a second sighting within the hour is refused and changes nothing" do
      user = insert_activated_user()
      ad = insert(:ad, day: Ads.today())

      assert Ads.record_sighting(user, {:ad, ad}, ~U[2026-09-17 08:02:00Z]) == :ok
      assert Ads.record_sighting(user, {:ad, ad}, ~U[2026-09-17 08:40:00Z]) == :capped

      assert Repo.reload!(user).ad_seen_at == ~U[2026-09-17 08:02:00Z]
      assert [%Sighting{times_seen: 1}] = Repo.all(Sighting)
    end

    test "the house ad takes the member's hour but is no sighting" do
      user = insert_activated_user()
      now = ~U[2026-09-17 08:02:00Z]

      Ads.record_sighting(user, :house, now)

      assert Repo.reload!(user).ad_seen_at == now
      assert Repo.all(Sighting) == []
    end

    test "deleting the member takes their sightings with them" do
      user = insert_activated_user()
      Ads.record_sighting(user, {:ad, insert(:ad, day: Ads.today())})

      Vutuv.Accounts.delete_user(user)

      assert Repo.all(Sighting) == []
    end
  end

  describe "seen_ads/2" do
    test "lists the member's own sightings, most recently seen first" do
      user = insert_activated_user()
      older = insert_ad_sighting(user, ~D[2026-09-10])
      newer = insert_ad_sighting(user, ~D[2026-09-12], times_seen: 3)
      insert_ad_sighting(insert_activated_user(), ~D[2026-09-11])

      assert {[first, second], false} = Ads.seen_ads(user)

      assert {first.id, first.times_seen, first.ad.content} ==
               {newer.id, 3, newer.ad.content}

      assert second.id == older.id
    end

    test "searches the ad text, ignoring case and treating wildcards literally" do
      user = insert_activated_user()
      match = insert_ad_sighting(user, ~D[2026-09-10], content: "Wann sind **Ferien** 2027?")
      insert_ad_sighting(user, ~D[2026-09-11], content: "Backend-Entwicklung in Mainz")
      insert_ad_sighting(user, ~D[2026-09-12], content: "100% Rabatt")

      assert {[%{id: id}], false} = Ads.seen_ads(user, query: "ferien")
      assert id == match.id
      assert {[_hit], false} = Ads.seen_ads(user, query: "100%")
      assert {[], false} = Ads.seen_ads(user, query: "0_ R")
    end

    test "pages by the last row it handed out" do
      user = insert_activated_user()
      for n <- 1..5, do: insert_ad_sighting(user, Date.add(~D[2026-09-01], n))

      assert {page, true} = Ads.seen_ads(user, limit: 2)
      assert length(page) == 2
      assert {rest, false} = Ads.seen_ads(user, limit: 3, after: List.last(page))
      assert length(rest) == 3

      assert Enum.map(page ++ rest, & &1.ad.day) ==
               Enum.map(5..1//-1, &Date.add(~D[2026-09-01], &1))
    end

    test "forget_old_sightings/1 drops what lies more than 90 days back" do
      user = insert_activated_user()
      old = insert_ad_sighting(user, ~D[2026-06-18])
      kept = insert_ad_sighting(user, ~D[2026-06-20])

      assert Ads.forget_old_sightings(~U[2026-09-17 12:00:00Z]) == 1
      assert {[%{id: id}], false} = Ads.seen_ads(user)
      assert id == kept.id
      refute Repo.get(Sighting, old.id)
    end

    test "forget_old_sightings/1 also finds an ad whose Berlin day began on the cutoff's" do
      user = insert_activated_user()
      # 00:30 in Berlin on 21 June, 22:30 UTC the evening before.
      late = insert_ad_sighting(user, ~D[2026-06-21], at: ~U[2026-06-20 22:30:00Z])

      assert Ads.forget_old_sightings(~U[2026-09-18 23:00:00Z]) == 1
      refute Repo.get(Sighting, late.id)
    end
  end

  describe "todays_ad/1" do
    test "is today's approved ad" do
      ad = insert(:ad, day: Ads.today())

      assert %Ad{id: id} = Ads.todays_ad(ad.id)
      assert id == ad.id
    end

    test "is nothing for an ad that may not serve now, or no ad at all" do
      unapproved = insert(:ad, day: Ads.today(), approved_at: nil)
      yesterdays = insert(:ad, day: Date.add(Ads.today(), -1))

      assert Ads.todays_ad(unapproved.id) == nil
      assert Ads.todays_ad(yesterdays.id) == nil
      assert Ads.todays_ad(Vutuv.UUIDv7.generate()) == nil
      assert Ads.todays_ad("not-an-id") == nil
    end
  end

  describe "berlin_date/1" do
    test "applies CET in winter and CEST in summer" do
      assert Ads.berlin_date(~U[2026-01-10 22:30:00Z]) == ~D[2026-01-10]
      assert Ads.berlin_date(~U[2026-01-10 23:30:00Z]) == ~D[2026-01-11]
      assert Ads.berlin_date(~U[2026-07-10 21:30:00Z]) == ~D[2026-07-10]
      assert Ads.berlin_date(~U[2026-07-10 22:30:00Z]) == ~D[2026-07-11]
    end

    test "switches on the last Sundays of March and October, 01:00 UTC" do
      # 2026: DST starts March 29, ends October 25.
      assert Ads.berlin_date(~U[2026-03-29 00:59:00Z]) == ~D[2026-03-29]
      assert Ads.berlin_date(~U[2026-03-29 22:30:00Z]) == ~D[2026-03-30]
      assert Ads.berlin_date(~U[2026-10-25 00:30:00Z]) == ~D[2026-10-25]
      assert Ads.berlin_date(~U[2026-10-25 22:30:00Z]) == ~D[2026-10-25]
    end
  end
end
