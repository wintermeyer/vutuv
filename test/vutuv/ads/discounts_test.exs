defmodule Vutuv.Ads.DiscountsTest do
  @moduledoc """
  Discount codes for ad bookings.

  The rules being pinned are the ones that decide money: what a code is worth,
  who may use it, how often, and the two moments a booking gives it back.
  """
  use Vutuv.DataCase, async: true
  import Vutuv.MailboxHelpers

  alias Vutuv.Ads
  alias Vutuv.Ads.Ad
  alias Vutuv.Ads.DiscountCode
  alias Vutuv.Ads.DiscountRedemption
  alias Vutuv.Ads.Discounts

  @booking %{
    "title" => "Acme sucht Leute",
    "body" => "Elixir in Mainz.",
    "url" => "https://acme.example",
    "billing_name" => "Acme GmbH",
    "billing_street" => "Musterstraße 1",
    "billing_zip_code" => "10115",
    "billing_city" => "Berlin"
  }

  defp booker do
    user = insert_activated_user()
    insert(:email, user: user, value: "bea-#{System.unique_integer([:positive])}@example.com")
    user
  end

  defp admin, do: insert_activated_user()

  defp code(attrs \\ %{}) do
    {:ok, code} =
      Discounts.create_code(
        admin(),
        Map.merge(%{"percent_off" => 20, "expires_on" => in_days(30)}, attrs)
      )

    code
  end

  defp in_days(n), do: Ads.today() |> Date.add(n) |> Date.to_iso8601()

  defp book(user, code_id, days \\ 1) do
    attrs =
      @booking
      |> Map.put("day", Date.to_iso8601(Ads.next_available_day()))
      |> Map.put("discount_code", code_id)

    result = Ads.book_ad(user, attrs, days)
    flush_emails()
    result
  end

  describe "making a code" do
    test "percent or euro, never both and never neither" do
      assert {:error, changeset} =
               Discounts.create_code(admin(), %{
                 "percent_off" => 20,
                 "cents_off" => 5000,
                 "expires_on" => in_days(30)
               })

      assert errors_on(changeset).percent_off != []

      assert {:error, changeset} = Discounts.create_code(admin(), %{"expires_on" => in_days(30)})
      assert errors_on(changeset).percent_off != []
    end

    test "the limits Stefan set are the limits" do
      for percent <- [0, 101] do
        assert {:error, _} =
                 Discounts.create_code(admin(), %{
                   "percent_off" => percent,
                   "expires_on" => in_days(30)
                 })
      end

      for cents <- [99, 300_001] do
        assert {:error, _} =
                 Discounts.create_code(admin(), %{
                   "cents_off" => cents,
                   "expires_on" => in_days(30)
                 })
      end

      assert %DiscountCode{} = code(%{"percent_off" => 1})
      assert %DiscountCode{} = code(%{"percent_off" => 100})
      assert %DiscountCode{percent_off: nil} = code(%{"percent_off" => nil, "cents_off" => 100})
      assert %DiscountCode{} = code(%{"percent_off" => nil, "cents_off" => 300_000})
    end

    test "the code is its own id, so nothing can collide" do
      one = code()
      two = code()

      assert is_binary(one.id) and byte_size(one.id) == 36
      refute one.id == two.id
    end

    test "the default expiry is the end of the month four months out" do
      expected = Ads.today() |> Date.shift(month: 4) |> Date.end_of_month()
      assert DiscountCode.default_expiry() == expected
    end

    test "a day already gone is refused" do
      assert {:error, changeset} =
               Discounts.create_code(admin(), %{"percent_off" => 20, "expires_on" => in_days(-1)})

      assert errors_on(changeset).expires_on != []
    end
  end

  describe "what a code is worth" do
    test "percent, and never more than the price" do
      assert DiscountCode.discount_cents(%DiscountCode{percent_off: 20}, 35_000) == 7_000
      assert DiscountCode.discount_cents(%DiscountCode{percent_off: 100}, 35_000) == 35_000
    end

    test "euro, capped at the price so a booking is never negative" do
      assert DiscountCode.discount_cents(%DiscountCode{cents_off: 5_000}, 35_000) == 5_000
      assert DiscountCode.discount_cents(%DiscountCode{cents_off: 300_000}, 35_000) == 35_000
    end
  end

  describe "who may use one" do
    test "an unknown, an expired and somebody else's code each say why" do
      user = booker()

      assert {:error, :blank} = Discounts.check("", user, 35_000)
      assert {:error, :unknown} = Discounts.check(Vutuv.UUIDv7.generate(), user, 35_000)
      assert {:error, :unknown} = Discounts.check("not-a-uuid", user, 35_000)

      # An expiry in the past cannot be created, so an existing code is aged.
      old = code()
      Repo.update_all(DiscountCode, set: [expires_on: Date.add(Ads.today(), -1)])
      assert {:error, :expired} = Discounts.check(old.id, user, 35_000)
      Repo.update_all(DiscountCode, set: [expires_on: Date.add(Ads.today(), 30)])

      theirs = code(%{"user_id" => booker().id})
      assert {:error, :not_yours} = Discounts.check(theirs.id, user, 35_000)
    end

    test "a code for everybody works once per member" do
      one = booker()
      two = booker()
      shared = code()

      assert {:ok, _, 7_000} = Discounts.check(shared.id, one, 35_000)
      assert {:ok, _} = book(one, shared.id)

      # Used up for that member, untouched for the next.
      assert {:error, :used} = Discounts.check(shared.id, one, 35_000)
      assert {:ok, _, 7_000} = Discounts.check(shared.id, two, 35_000)
    end

    test "a personalised code is good exactly once" do
      user = booker()
      mine = code(%{"user_id" => user.id})

      assert {:ok, _} = book(user, mine.id)
      assert {:error, :used} = Discounts.check(mine.id, user, 35_000)
    end
  end

  describe "what a booking is stamped with" do
    test "the discount is stamped beside the price, not folded into it" do
      user = booker()
      assert {:ok, ad} = book(user, code().id)

      # The invoice is written from the pair, so a code that later expires or
      # is deleted cannot change what was agreed.
      assert ad.price_cents == 35_000
      assert ad.discount_cents == 7_000
      assert ad.discount_code_id != nil
    end

    test "a week's discount is split so the shares add up to it" do
      user = booker()
      assert {:ok, ad} = book(user, code().id, 7)

      rows = Repo.all(from(a in Ad, where: a.group_id == ^ad.group_id))
      assert Enum.sum(Enum.map(rows, & &1.price_cents)) == 200_000
      # 20 % of the WEEK, not seven times 20 % of a day.
      assert Enum.sum(Enum.map(rows, & &1.discount_cents)) == 40_000
    end

    test "a code that is not usable books at the list price rather than failing" do
      user = booker()
      theirs = code(%{"user_id" => booker().id})

      # Nobody loses their week over a typo in a voucher.
      assert {:ok, ad} = book(user, theirs.id)
      assert ad.discount_cents == 0
      assert ad.discount_code_id == nil
    end

    test "a hundred percent books at nothing and still needs approval" do
      user = booker()
      assert {:ok, ad} = book(user, code(%{"percent_off" => 100}).id)

      assert ad.discount_cents == ad.price_cents
      assert ad.approved_at == nil
    end
  end

  describe "giving a code back" do
    test "a booking we turn down frees it again" do
      user = booker()
      shared = code()
      {:ok, ad} = book(user, shared.id)

      assert {:error, :used} = Discounts.check(shared.id, user, 35_000)
      assert {:ok, _} = Ads.reject_ad(ad, admin(), "Nicht passend.")
      flush_emails()

      # Nothing ran, so nothing was used.
      assert {:ok, _, 7_000} = Discounts.check(shared.id, user, 35_000)
      # ...and the history of the attempt survives.
      assert [%DiscountRedemption{released_at: at}] = Repo.all(DiscountRedemption)
      assert at != nil
    end

    test "cancelling before approval frees it again" do
      user = booker()
      shared = code()
      {:ok, ad} = book(user, shared.id)

      assert {:ok, _} = Ads.cancel_booking(ad, user)
      flush_emails()
      assert {:ok, _, 7_000} = Discounts.check(shared.id, user, 35_000)
    end

    test "taking a running ad off the site does NOT free it" do
      user = booker()
      shared = code()
      {:ok, ad} = book(user, shared.id)
      {:ok, _} = Ads.approve_ad(ad, admin())
      flush_emails()

      # Move it to today so it is running, then withdraw it.
      Repo.update_all(from(a in Ad, where: a.id == ^ad.id), set: [day: Ads.today()])
      running = Repo.get!(Ad, ad.id)

      assert {:ok, _} = Ads.withdraw_booking(running, user)
      flush_emails()

      # They had what they paid for.
      assert {:error, :used} = Discounts.check(shared.id, user, 35_000)
    end
  end

  describe "forgetting a code" do
    test "the bookings that used it keep their price" do
      user = booker()
      shared = code()
      {:ok, ad} = book(user, shared.id)

      assert {:ok, _} = Discounts.delete_code(shared.id)

      kept = Repo.get!(Ad, ad.id)
      assert kept.discount_cents == 7_000
      assert kept.price_cents == 35_000
    end
  end
end
