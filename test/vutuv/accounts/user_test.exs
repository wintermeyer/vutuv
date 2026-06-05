defmodule Vutuv.Accounts.UserTest do
  use Vutuv.DataCase

  alias Vutuv.Accounts.User

  @valid_attrs %{"first_name" => "first_name"}
  @invalid_email_attrs %{
    "first_name" => "first_name",
    "emails" => %{"0" => %{"value" => "invalid email"}}
  }

  test "changeset with valid attributes" do
    changeset = User.changeset(%User{}, @valid_attrs)
    assert changeset.valid?
  end

  test "changeset ignores email params (emails change only via the PIN flow)" do
    changeset = User.changeset(%User{}, @invalid_email_attrs)
    assert changeset.valid?
    refute Ecto.Changeset.get_change(changeset, :emails)
  end

  test "registration_changeset casts and validates the initial email" do
    changeset = User.registration_changeset(%User{}, @invalid_email_attrs)
    refute changeset.valid?
  end
end
