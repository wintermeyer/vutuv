defmodule Vutuv.AdsTest do
  use Vutuv.DataCase, async: true
  import Vutuv.MailboxHelpers

  alias Vutuv.Ads
  alias Vutuv.Ads.Ad

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
