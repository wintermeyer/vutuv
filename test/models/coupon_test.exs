defmodule Vutuv.Recruiting.CouponTest do
  use Vutuv.ModelCase

  alias Vutuv.Recruiting.Coupon

  @valid_attrs %{code: "ACDE2345", ends_on: %{day: 17, month: 4, year: 2030}, percentage: 42}
  @invalid_attrs %{}

  test "changeset with valid attributes" do
    changeset = Coupon.changeset(%Coupon{}, @valid_attrs)
    assert changeset.valid?
  end

  test "changeset with invalid attributes" do
    changeset = Coupon.changeset(%Coupon{}, @invalid_attrs)
    refute changeset.valid?
  end
end
