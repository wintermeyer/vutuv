defmodule Vutuv.Recruiting.RecruiterSubscriptionTest do
  use Vutuv.ModelCase

  import Vutuv.Factory

  alias Vutuv.Recruiting.RecruiterSubscription

  @valid_attrs %{
    line1: "Some Company",
    street: "123 Main St",
    zip_code: "12345",
    city: "Berlin",
    country: "Germany"
  }
  @invalid_attrs %{}

  test "changeset with valid attributes" do
    package = insert(:recruiter_package)
    attrs = Map.put(@valid_attrs, :recruiter_package_id, package.id)

    changeset = RecruiterSubscription.changeset(%RecruiterSubscription{}, attrs)

    assert changeset.valid?
  end

  test "changeset with invalid attributes" do
    changeset = RecruiterSubscription.changeset(%RecruiterSubscription{}, @invalid_attrs)
    refute changeset.valid?
  end

  test "set_dates/1 sets begin today and end duration_in_months out (month overflow safe)" do
    package = insert(:recruiter_package, duration_in_months: 18)
    attrs = Map.put(@valid_attrs, :recruiter_package_id, package.id)

    changeset = RecruiterSubscription.changeset(%RecruiterSubscription{}, attrs)

    today = Date.utc_today()
    expected_end = today |> Date.beginning_of_month() |> Date.shift(month: 18)

    assert get_change(changeset, :subscription_begins) == today
    assert get_change(changeset, :subscription_ends) == expected_end
  end

  test "changeset with an unknown recruiter_package_id is invalid (does not raise)" do
    attrs = Map.put(@valid_attrs, :recruiter_package_id, 999_999)

    changeset = RecruiterSubscription.changeset(%RecruiterSubscription{}, attrs)

    refute changeset.valid?
    assert {"Something went wrong", _} = changeset.errors[:recruiter_package_id]
  end
end
