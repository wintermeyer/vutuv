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

  describe "identity verification revocation" do
    # A member an admin has already verified (their physical ID was checked
    # against this name and birthday).
    defp verified_user do
      %User{
        identity_verified?: true,
        first_name: "Erika",
        last_name: "Mustermann",
        birthdate: ~D[1980-01-01]
      }
    end

    test "changing the first name revokes the verification" do
      changeset = User.changeset(verified_user(), %{"first_name" => "Imposter"})
      assert Ecto.Changeset.get_change(changeset, :identity_verified?) == false
    end

    test "changing the last name revokes the verification" do
      changeset = User.changeset(verified_user(), %{"last_name" => "Other"})
      assert Ecto.Changeset.get_change(changeset, :identity_verified?) == false
    end

    test "changing the middle name revokes the verification" do
      changeset = User.changeset(verified_user(), %{"middle_name" => "Zweitname"})
      assert Ecto.Changeset.get_change(changeset, :identity_verified?) == false
    end

    test "changing the birthday revokes the verification" do
      changeset = User.changeset(verified_user(), %{"birthdate" => ~D[1990-12-31]})
      assert Ecto.Changeset.get_change(changeset, :identity_verified?) == false
    end

    test "changing the nickname revokes the verification" do
      changeset = User.changeset(verified_user(), %{"nickname" => "Eri"})
      assert Ecto.Changeset.get_change(changeset, :identity_verified?) == false
    end

    test "adding an honorific title revokes the verification" do
      changeset = User.changeset(verified_user(), %{"honorific_prefix" => "Dr."})
      assert Ecto.Changeset.get_change(changeset, :identity_verified?) == false
    end

    test "changing the gender revokes the verification" do
      changeset = User.changeset(verified_user(), %{"gender" => "female"})
      assert Ecto.Changeset.get_change(changeset, :identity_verified?) == false
    end

    test "editing a non-identity field (headline) keeps the verification" do
      changeset = User.changeset(verified_user(), %{"headline" => "Now hiring"})
      refute Ecto.Changeset.get_change(changeset, :identity_verified?)
    end

    test "resubmitting the same name and birthday keeps the verification" do
      changeset =
        User.changeset(verified_user(), %{
          "first_name" => "Erika",
          "last_name" => "Mustermann",
          "birthdate" => ~D[1980-01-01]
        })

      refute Ecto.Changeset.get_change(changeset, :identity_verified?)
    end

    test "an unverified member never gets a spurious verification change" do
      unverified = %User{identity_verified?: false, first_name: "Erika"}
      changeset = User.changeset(unverified, %{"first_name" => "Imposter"})
      refute Ecto.Changeset.get_change(changeset, :identity_verified?)
    end
  end

  describe "tag list" do
    defp tag_list_changeset(tag_list) do
      User.changeset(%User{}, %{"first_name" => "first_name", "tag_list" => tag_list})
    end

    # The virtual `tag_list` is not validated on the changeset: it is split into
    # real tags after the row commits (Accounts.register_user/3), on both commas
    # and spaces, so any string is accepted here. A run of words is no longer an
    # error, it just becomes several tags. See tags_test.exs / page_controller_test.exs.
    test "accepts a comma-separated list" do
      assert tag_list_changeset("Elixir, Cooking, Go").valid?
    end

    test "accepts a run of space-separated words" do
      assert tag_list_changeset("JavaScript Go Hunde").valid?
    end

    test "accepts no tags at all" do
      assert User.changeset(%User{}, %{"first_name" => "first_name"}).valid?
    end
  end
end
