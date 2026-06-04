defmodule Vutuv.Recruiting.RecruiterPackageTest do
  use Vutuv.DataCase

  alias Vutuv.Recruiting.RecruiterPackage

  @valid_attrs %{
    name: "Basic Plan",
    description: "A basic package",
    locale_id: 1,
    price: 99.99,
    currency: "EUR",
    duration_in_months: 12,
    auto_renewal: true,
    offer_begins: ~D[2026-01-01],
    offer_ends: ~D[2026-12-31],
    max_job_postings: 10,
    only_with_coupon: false
  }
  @invalid_attrs %{}

  test "changeset with valid attributes" do
    changeset = RecruiterPackage.changeset(%RecruiterPackage{}, @valid_attrs)
    assert changeset.valid?
  end

  test "changeset with invalid attributes" do
    changeset = RecruiterPackage.changeset(%RecruiterPackage{}, @invalid_attrs)
    refute changeset.valid?
  end
end
