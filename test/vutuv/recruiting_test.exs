defmodule Vutuv.RecruitingTest do
  use Vutuv.DataCase

  import Ecto.Query
  alias Vutuv.Recruiting

  describe "recruiter_packages" do
    test "list_packages/0 returns all packages" do
      locale = Vutuv.Repo.one(from(l in Vutuv.Accounts.Locale, limit: 1))
      package = insert(:recruiter_package, locale: locale)
      assert Enum.any?(Recruiting.list_packages(), &(&1.id == package.id))
    end

    test "get_package!/1 returns the package" do
      locale = Vutuv.Repo.one(from(l in Vutuv.Accounts.Locale, limit: 1))
      package = insert(:recruiter_package, locale: locale)
      assert Recruiting.get_package!(package.id).id == package.id
    end
  end

  describe "coupons" do
    test "get_coupon_by_code/1 returns coupon" do
      coupon = insert(:coupon)
      assert Recruiting.get_coupon_by_code(coupon.code).id == coupon.id
    end

    test "get_coupon_by_code/1 returns nil for unknown code" do
      assert Recruiting.get_coupon_by_code("ZZZZZZZZ") == nil
    end
  end
end
