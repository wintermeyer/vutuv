defmodule Vutuv.AdsTest do
  use Vutuv.DataCase, async: true
  import Vutuv.MailboxHelpers

  alias Vutuv.Ads
  alias Vutuv.Ads.Ad
  alias Vutuv.Ads.Sighting

  @valid_attrs %{
    "day" => Date.to_iso8601(Date.add(Ads.today(), 7)),
    "title" => "Acme sucht Leute",
    "body" => "Elixir-Entwicklung in Mainz, gern auch remote.",
    "url" => "https://www.acme.example/jobs/?utm_source=vutuv",
    "billing_name" => "Acme GmbH",
    "billing_street" => "Musterstraße 1",
    "billing_zip_code" => "10115",
    "billing_city" => "Berlin",
    "billing_country" => "Deutschland"
  }

  @operator "sw@wintermeyer-consulting.de"

  # A member with an address to write to; `locale` picks the mail's language.
  defp booker(locale \\ "en") do
    user = insert_activated_user(first_name: "Bea", last_name: "Bucher", locale: locale)
    insert(:email, user: user, value: "bea-#{System.unique_integer([:positive])}@example.com")
    user
  end

  defp admin, do: insert_activated_user(first_name: "Ada", last_name: "Admin")

  # The mails in `mails` that went to `user`'s address, and to the operator.
  defp mails_to(mails, %Vutuv.Accounts.User{} = user) do
    address = Vutuv.Accounts.first_email_value(user)
    Enum.filter(mails, fn mail -> Enum.any?(mail.to, fn {_, to} -> to == address end) end)
  end

  defp mails_to(mails, @operator) do
    Enum.filter(mails, fn mail -> Enum.any?(mail.to, fn {_, to} -> to == @operator end) end)
  end

  # How many rows of `ad`'s block carry `field`, which is how a decision that
  # must move the whole purchase is checked.
  defp group_count(%Ad{group_id: group_id}, field) do
    Repo.aggregate(
      from(a in Ad, where: a.group_id == ^group_id and not is_nil(field(a, ^field))),
      :count
    )
  end

  defp pending_booking(user \\ booker()) do
    {:ok, ad} = Ads.book_ad(user, @valid_attrs)
    flush_emails()
    ad
  end

  describe "VAT on top of every quoted price" do
    test "the stamped price is net and the gross adds the configured rate" do
      # 350,00 € net, 19 % -> 416,50 €. Cent-exact, so a rate that does not
      # divide evenly still lands on a real invoice amount.
      assert Ads.price_cents() == 35_000
      assert Ads.vat_percent() == 19
      assert Ads.vat_cents(35_000) == 6_650
      assert Ads.gross_cents(35_000) == 41_650
      assert Ads.vat_cents(99_999) == 19_000
    end
  end

  describe "booking a week or a month" do
    test "the tiers are cheaper per day the longer they run" do
      assert [one, week, month] = Ads.tiers()
      assert {one.days, one.cents} == {1, 35_000}
      assert {week.days, week.cents} == {7, 200_000}
      assert {month.days, month.cents} == {30, 750_000}

      assert Ads.tier_day_cents(week) == 28_571
      assert Ads.tier_discount_percent(week) == 18
      assert Ads.tier_day_cents(month) == 25_000
      assert Ads.tier_discount_percent(month) == 29
    end

    test "a week is seven rows sharing one purchase, adding up to the tier price" do
      user = booker()
      first = Ads.next_available_day()
      attrs = Map.put(@valid_attrs, "day", Date.to_iso8601(first))

      assert {:ok, %Ad{} = ad} = Ads.book_ad(user, attrs, 7)
      assert ad.day == first
      assert is_binary(ad.group_id)

      rows = Repo.all(from(a in Ad, where: a.group_id == ^ad.group_id, order_by: a.day))
      assert length(rows) == 7
      assert Enum.map(rows, & &1.day) == Ads.block_days(first, 7)
      assert Enum.sum(Enum.map(rows, & &1.price_cents)) == 200_000

      # One purchase, so the booker hears about it once.
      assert [_operator, _booker] = flush_emails()
    end

    test "a day somebody else holds takes the whole block down with it" do
      taken = Date.add(Ads.next_available_day(), 3)

      assert {:ok, _} =
               Ads.book_ad(booker(), Map.put(@valid_attrs, "day", Date.to_iso8601(taken)))

      flush_emails()

      first = Ads.next_available_day()
      attrs = Map.put(@valid_attrs, "day", Date.to_iso8601(first))

      assert {:error, changeset} = Ads.book_ad(booker(), attrs, 7)
      assert "has already been booked" in errors_on(changeset).day
      # Nothing of the block survives, so the free days it touched are free.
      assert Repo.aggregate(from(a in Ad, where: a.day == ^first), :count) == 0
      assert flush_emails() == []
    end

    test "a block past the window is refused about the day the member picked" do
      first = Date.add(Ads.last_bookable_day(), -3)
      attrs = Map.put(@valid_attrs, "day", Date.to_iso8601(first))

      assert {:error, changeset} = Ads.book_ad(booker(), attrs, 7)
      assert "is outside the booking window" in errors_on(changeset).day
      assert Repo.aggregate(from(a in Ad, where: a.day == ^first), :count) == 0

      # Each row validates its own day, so without the block's own check the
      # error would come back on the seventh day - a day the member never chose,
      # which the form would then select in the calendar for them.
      assert Ecto.Changeset.get_field(changeset, :day) == first
    end

    test "a length nobody sells books nothing" do
      assert {:error, changeset} = Ads.book_ad(booker(), @valid_attrs, 3)
      assert errors_on(changeset).day != []
      assert Repo.aggregate(from(a in Ad), :count) == 0
    end

    test "one decision moves the whole block: approving, rejecting, cancelling" do
      user = booker()
      first = Ads.next_available_day()
      attrs = Map.put(@valid_attrs, "day", Date.to_iso8601(first))
      assert {:ok, ad} = Ads.book_ad(user, attrs, 7)
      flush_emails()

      assert {:ok, approved} = Ads.approve_ad(ad, admin())
      assert approved.day == first
      assert group_count(ad, :approved_at) == 7
      # And once, not seven times.
      assert [_one] = mails_to(flush_emails(), user)

      assert {:ok, _} = Ads.cancel_ad(ad, admin())
      assert group_count(ad, :cancelled_at) == 7
      assert [_one] = mails_to(flush_emails(), user)
    end

    test "the booker cancels the week they bought, not one day of it" do
      user = booker()
      first = Ads.next_available_day()
      attrs = Map.put(@valid_attrs, "day", Date.to_iso8601(first))
      assert {:ok, ad} = Ads.book_ad(user, attrs, 7)
      flush_emails()

      assert {:ok, _} = Ads.cancel_booking(ad, user)
      assert group_count(ad, :cancelled_at) == 7
      # Every day is free again, so the same week books a second time.
      assert {:ok, _} = Ads.book_ad(booker(), attrs, 7)
    end

    test "the mails name the whole week and the price of the week" do
      user = booker("de")
      first = Ads.next_available_day()
      last = Date.add(first, 6)
      attrs = Map.put(@valid_attrs, "day", Date.to_iso8601(first))

      assert {:ok, _ad} = Ads.book_ad(user, attrs, 7)
      mails = flush_emails()

      # A row of a block carries one day and one seventh of the price, and
      # neither is what the invoice says - so neither may reach a mail.
      for mail <- mails do
        assert mail.text_body =~ Calendar.strftime(first, "%d.%m.%Y")
        assert mail.text_body =~ Calendar.strftime(last, "%d.%m.%Y")
        assert mail.text_body =~ "2.000,00"
        refute mail.text_body =~ "285,71"
      end

      assert [operator] = mails_to(mails, @operator)
      assert operator.subject =~ Calendar.strftime(last, "%d.%m.%Y")

      # The mail is built on a task whose process locale is the installation
      # default, so the range's own joining word has to be the member's.
      assert [booker_mail] = mails_to(mails, user)
      assert booker_mail.subject =~ Calendar.strftime(last, "%d.%m.%Y")
      assert booker_mail.subject =~ "bis"
      refute booker_mail.subject =~ " to "
      assert booker_mail.text_body =~ "bis"
    end

    test "my bookings shows a week as one line at its own price" do
      user = booker()
      first = Ads.next_available_day()
      attrs = Map.put(@valid_attrs, "day", Date.to_iso8601(first))
      assert {:ok, _} = Ads.book_ad(user, attrs, 7)
      flush_emails()

      assert [booking] = Ads.user_bookings(user)
      assert booking.days == 7
      assert booking.ad.day == first
      assert booking.last_day == Date.add(first, 6)
      assert booking.price_cents == 200_000
    end

    test "a start day the block does not fit behind is refused by the preview" do
      taken = Date.add(Ads.next_available_day(), 2)

      assert {:ok, _} =
               Ads.book_ad(booker(), Map.put(@valid_attrs, "day", Date.to_iso8601(taken)))

      flush_emails()

      first = Ads.next_available_day()
      attrs = Map.put(@valid_attrs, "day", Date.to_iso8601(first))

      assert {:error, changeset} = Ads.preview_ad(attrs, 7)
      assert "has already been booked" in errors_on(changeset).day
      # The same start is fine for a single day, which is what free_block? says.
      assert {:ok, _} = Ads.preview_ad(attrs, 1)
      assert Ads.free_block?(first, 1)
      refute Ads.free_block?(first, 7)
    end
  end

  describe "book_ad/2" do
    test "books the day, stamps the fixed price and mails the booking" do
      user = booker()

      assert {:ok, %Ad{} = ad} = Ads.book_ad(user, @valid_attrs)
      assert ad.user_id == user.id
      assert ad.price_cents == 35_000
      assert ad.day == Date.add(Ads.today(), 7)

      assert [email] = mails_to(flush_emails(), @operator)
      assert email.to == [{"Stefan Wintermeyer", "sw@wintermeyer-consulting.de"}]
      # The mail carries everything the manual invoice needs: billing data,
      # the booked day and the full ad text.
      assert email.text_body =~ "Acme GmbH"
      assert email.text_body =~ "Musterstraße 1"
      assert email.text_body =~ "10115"
      assert email.text_body =~ "350,00"
      assert email.text_body =~ @valid_attrs["title"]
      assert email.text_body =~ @valid_attrs["body"]
      assert email.text_body =~ @valid_attrs["url"]
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

    test "caps the title at 30 characters and the text at 90" do
      attrs = %{
        @valid_attrs
        | "title" => String.duplicate("ä", 31),
          "body" => String.duplicate("ü", 91)
      }

      assert {:error, changeset} = Ads.book_ad(booker(), attrs)
      assert %{title: [_], body: [_]} = errors_on(changeset)

      attrs = %{
        @valid_attrs
        | "title" => String.duplicate("ä", 30),
          "body" => String.duplicate("ü", 90)
      }

      assert {:ok, _ad} = Ads.book_ad(booker(), attrs)
      flush_emails()
    end

    test "requires a title, a text and a link, and trims them" do
      attrs = %{@valid_attrs | "title" => "  ", "body" => "", "url" => " "}
      assert {:error, changeset} = Ads.book_ad(booker(), attrs)
      assert %{title: [_], body: [_], url: [_]} = errors_on(changeset)

      attrs = %{@valid_attrs | "title" => "  Acme  ", "url" => " https://acme.example "}
      assert {:ok, ad} = Ads.book_ad(booker(), attrs)
      assert {ad.title, ad.url} == {"Acme", "https://acme.example"}
      flush_emails()
    end

    test "the link must be a web address" do
      for url <- ["javascript:alert(1)", "ftp://acme.example", "acme", "https://localhost/x"] do
        assert {:error, changeset} = Ads.book_ad(booker(), %{@valid_attrs | "url" => url})
        assert %{url: [_]} = errors_on(changeset), "#{url} was accepted"
      end
    end

    test "requires the billing address" do
      attrs = Map.drop(@valid_attrs, ["billing_name", "billing_street"])
      assert {:error, changeset} = Ads.book_ad(booker(), attrs)
      assert %{billing_name: [_], billing_street: [_]} = errors_on(changeset)
    end
  end

  describe "the booker hears from us" do
    test "a booking is confirmed to the booker, in their own language" do
      user = booker("de")
      assert {:ok, ad} = Ads.book_ad(user, @valid_attrs)

      assert [mail] = mails_to(flush_emails(), user)
      assert mail.subject =~ Calendar.strftime(ad.day, "%d.%m.%Y")
      assert mail.text_body =~ "Acme sucht Leute"
      assert mail.text_body =~ "https://www.acme.example/jobs/?utm_source=vutuv"
      assert mail.text_body =~ "350,00"
      assert mail.text_body =~ "system/ads/bookings"
      assert mail.text_body =~ "stornieren"
    end

    test "a booker with no address to write to only reaches the operator" do
      user = insert_activated_user()
      assert {:ok, _ad} = Ads.book_ad(user, @valid_attrs)
      assert [%{to: [{_, @operator}]}] = flush_emails()
    end

    test "the approval is announced once, with the day in the member's date format" do
      user = booker()

      Repo.update_all(from(u in Vutuv.Accounts.User, where: u.id == ^user.id),
        set: [date_region: "ISO"]
      )

      ad = pending_booking(user)

      assert {:ok, approved} = Ads.approve_ad(ad, admin())
      assert [mail] = mails_to(flush_emails(), user)
      assert mail.subject =~ "approved"
      assert mail.subject =~ Date.to_iso8601(ad.day)
      assert mail.text_body =~ Date.to_iso8601(ad.day)

      assert {:ok, _} = Ads.approve_ad(approved, admin())
      assert flush_emails() == []
    end

    test "a second admin approving from the same stale page gets the approval, not an error" do
      ad = pending_booking()

      assert {:ok, first} = Ads.approve_ad(ad, admin())
      assert {:ok, second} = Ads.approve_ad(ad, admin())
      assert second.approved_by_id == first.approved_by_id
    end
  end

  describe "approve_ad/2" do
    test "stamps the approval and the approving admin" do
      ad = pending_booking()
      admin = admin()

      assert ad.approved_at == nil
      assert {:ok, approved} = Ads.approve_ad(ad, admin)
      assert approved.approved_at
      assert approved.approved_by_id == admin.id
    end

    test "never approves a rejected or cancelled ad" do
      rejected = insert(:ad, approved_at: nil, rejected_at: ~U[2026-09-01 10:00:00Z])
      cancelled = insert(:ad, approved_at: nil, cancelled_at: ~U[2026-09-01 10:00:00Z])

      assert {:error, :not_pending} = Ads.approve_ad(rejected, admin())
      assert {:error, :not_pending} = Ads.approve_ad(cancelled, admin())
      assert Repo.reload!(rejected).approved_at == nil
    end

    test "is idempotent: a second approval keeps the first stamp" do
      ad = pending_booking()
      admin = admin()
      other_admin = admin()

      {:ok, approved} = Ads.approve_ad(ad, admin)
      {:ok, still} = Ads.approve_ad(approved, other_admin)
      assert still.approved_at == approved.approved_at
      assert still.approved_by_id == admin.id
    end
  end

  describe "reject_ad/3" do
    test "turns a pending ad down, and the booker reads why" do
      user = booker("de")
      ad = pending_booking(user)
      admin = admin()

      assert {:ok, rejected} = Ads.reject_ad(ad, admin, "  Nicht familienfreundlich.  ")
      assert rejected.rejected_at
      assert rejected.rejected_by_id == admin.id
      assert rejected.rejection_reason == "Nicht familienfreundlich."

      assert [mail] = mails_to(flush_emails(), user)
      assert mail.text_body =~ "Nicht familienfreundlich."
      assert mail.text_body =~ Calendar.strftime(ad.day, "%d.%m.%Y")
    end

    test "needs a reason" do
      ad = pending_booking()

      assert {:error, changeset} = Ads.reject_ad(ad, admin(), "   ")
      assert %{rejection_reason: [_]} = errors_on(changeset)
      assert Repo.reload!(ad).rejected_at == nil
      assert flush_emails() == []
    end

    test "frees the day for somebody else, and the rejected ad never runs" do
      today = insert(:ad, day: Ads.today(), approved_at: nil)
      assert {:ok, _} = Ads.reject_ad(today, admin(), "Nein.")
      assert Ads.current_banner() == :house

      first = Ads.first_bookable_day()
      ad = insert(:ad, day: first, approved_at: nil)
      assert {:ok, _} = Ads.reject_ad(ad, admin(), "Nein.")
      refute MapSet.member?(Ads.booked_days(), first)
      assert Ads.next_available_day() == first

      assert {:ok, again} =
               Ads.book_ad(booker(), %{@valid_attrs | "day" => Date.to_iso8601(first)})

      assert again.day == first
      flush_emails()
    end

    test "only while the ad waits for approval" do
      assert {:error, :not_pending} = Ads.reject_ad(insert(:ad), admin(), "Zu spät.")
    end
  end

  describe "cancel_booking/2" do
    test "the booker withdraws a pending booking, and the operator hears of it" do
      user = booker()
      ad = pending_booking(user)

      assert {:ok, cancelled} = Ads.cancel_booking(ad, user)
      assert cancelled.cancelled_at
      assert cancelled.cancelled_by_id == user.id
      refute MapSet.member?(Ads.booked_days(), ad.day)

      assert [notice] = flush_emails()
      assert notice.to == [{"Stefan Wintermeyer", @operator}]
      assert notice.subject =~ "Stornierung"
      assert notice.text_body =~ "Acme sucht Leute"
    end

    test "not once the ad is approved, and never somebody else's" do
      user = booker()
      approved = insert(:ad, user: user)
      pending = insert(:ad, day: Date.add(Ads.first_bookable_day(), 1), approved_at: nil)

      assert {:error, :not_pending} = Ads.cancel_booking(approved, user)
      assert {:error, :not_found} = Ads.cancel_booking(pending, user)
      assert Repo.reload!(approved).cancelled_at == nil
      assert Repo.reload!(pending).cancelled_at == nil
      assert flush_emails() == []
    end
  end

  describe "cancel_ad/2" do
    test "an admin takes an approved ad off its day and tells the booker" do
      user = booker()
      ad = insert(:ad, day: Ads.today(), user: user)
      admin = admin()

      assert {:ok, cancelled} = Ads.cancel_ad(ad, admin)
      assert cancelled.cancelled_by_id == admin.id
      assert Ads.current_banner() == :house

      assert [mail] = mails_to(flush_emails(), user)
      assert mail.subject =~ "cancelled"
    end

    test "leaves a day that is over alone" do
      past = insert(:ad, day: Date.add(Ads.today(), -1))
      assert {:error, :not_pending} = Ads.cancel_ad(past, admin())
    end
  end

  describe "the numbers a booking gets" do
    test "views and clicks add up per booked ad, the house ad counts nothing" do
      ad = insert(:ad)

      Ads.count_view({:ad, ad})
      Ads.count_view({:ad, ad})
      Ads.count_click({:ad, ad})
      assert :ok = Ads.count_view(:house)
      assert :ok = Ads.count_click(:house)

      assert %{views_count: 2, clicks_count: 1} = Repo.reload!(ad)
    end

    test "a member's sighting is a view only when it takes the hour" do
      ad = insert(:ad, day: Ads.today())
      user = insert_activated_user()

      assert :ok = Ads.record_sighting(user, {:ad, ad})
      assert :capped = Ads.record_sighting(Repo.reload!(user), {:ad, ad})
      assert Repo.reload!(ad).views_count == 1
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

    test "an ad booked in the old Markdown format, with no title, never runs" do
      insert(:ad, day: Ads.today(), title: nil, body: nil, url: nil)
      assert Ads.current_banner() == :house
    end
  end

  describe "Ad.display_url/1" do
    test "is the host without www and the path, never the query or the fragment" do
      assert Ad.display_url("https://www.Acme.example/jobs/?utm_source=vutuv#top") ==
               "acme.example/jobs"

      assert Ad.display_url("http://acme.example") == "acme.example"
      assert Ad.display_url("https://acme.example/") == "acme.example"

      assert Ad.display_url("https://shop.acme.example/de/angebot") ==
               "shop.acme.example/de/angebot"
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

      assert {first.id, first.times_seen, first.ad.title} ==
               {newer.id, 3, newer.ad.title}

      assert second.id == older.id
    end

    test "searches title, text and link, ignoring case and treating wildcards literally" do
      user = insert_activated_user()

      holidays =
        insert_ad_sighting(user, ~D[2026-09-10],
          title: "Wann sind Ferien 2027?",
          url: "https://www.mehr-schulferien.de/?ref=newsletter#top"
        )

      jobs = insert_ad_sighting(user, ~D[2026-09-11], body: "Backend-Entwicklung in Mainz")
      insert_ad_sighting(user, ~D[2026-09-12], title: "100% Rabatt")

      holidays_id = holidays.id
      jobs_id = jobs.id
      assert {[%{id: ^holidays_id}], false} = Ads.seen_ads(user, query: "FERIEN")
      assert {[%{id: ^holidays_id}], false} = Ads.seen_ads(user, query: "schulferien.de")
      assert {[%{id: ^jobs_id}], false} = Ads.seen_ads(user, query: "mainz")
      # The query and fragment are not shown, so they are not searched either.
      assert {[], false} = Ads.seen_ads(user, query: "newsletter")
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
