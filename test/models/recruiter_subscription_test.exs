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

  test "public changeset ignores privileged payment fields (no mass assignment)" do
    package = insert(:recruiter_package)

    attrs =
      @valid_attrs
      |> Map.put(:recruiter_package_id, package.id)
      |> Map.merge(%{
        paid: true,
        paid_on: ~D[2020-01-01],
        invoice_number: "INV-1",
        invoiced_on: ~D[2020-01-01]
      })

    changeset = RecruiterSubscription.changeset(%RecruiterSubscription{}, attrs)

    assert changeset.valid?
    assert get_change(changeset, :paid) == nil
    assert get_change(changeset, :paid_on) == nil
    assert get_change(changeset, :invoice_number) == nil
    assert get_change(changeset, :invoiced_on) == nil
  end

  test "public changeset ignores a client-supplied subscription_ends" do
    package = insert(:recruiter_package, duration_in_months: 12)

    attrs =
      @valid_attrs
      |> Map.put(:recruiter_package_id, package.id)
      |> Map.put(:subscription_ends, ~D[2099-12-31])

    changeset = RecruiterSubscription.changeset(%RecruiterSubscription{}, attrs)

    # set_dates derives the real end date from the package, the client value is dropped.
    today = Date.utc_today()
    expected_end = today |> Date.beginning_of_month() |> Date.shift(month: 12)
    assert get_change(changeset, :subscription_ends) == expected_end
  end

  test "payment_changeset lets the server set the privileged payment fields" do
    sub = insert(:recruiter_subscription)

    changeset =
      RecruiterSubscription.payment_changeset(sub, %{paid: true, paid_on: ~D[2026-06-04]})

    assert changeset.valid?
    assert get_change(changeset, :paid) == true
    assert get_change(changeset, :paid_on) == ~D[2026-06-04]
  end
end
