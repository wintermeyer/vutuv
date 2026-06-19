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

  describe "birthdate" do
    defp birthdate_changeset(birthdate) do
      User.changeset(%User{}, %{"first_name" => "first_name", "birthdate" => birthdate})
    end

    test "accepts a normal past date" do
      assert birthdate_changeset(~D[1990-05-15]).valid?
    end

    test "accepts no birthdate at all" do
      assert User.changeset(%User{}, %{"first_name" => "first_name"}).valid?
    end

    test "rejects a date in the future" do
      future = Date.add(Vutuv.BerlinTime.today(), 1)
      changeset = birthdate_changeset(future)

      refute changeset.valid?
      assert %{birthdate: [_]} = errors_on(changeset)
    end

    test "rejects an implausibly old date (more than 120 years ago)" do
      changeset = birthdate_changeset(~D[1800-01-01])

      refute changeset.valid?
      assert %{birthdate: [_]} = errors_on(changeset)
    end

    test "still nils out the 1900-01-01 \"unset\" sentinel without erroring" do
      changeset = birthdate_changeset(~D[1900-01-01])

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :birthdate) == nil
    end
  end
end
