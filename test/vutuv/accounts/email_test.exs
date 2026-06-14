defmodule Vutuv.Accounts.EmailTest do
  use Vutuv.DataCase, async: true

  alias Vutuv.Accounts.Email

  describe "email_type" do
    test "defaults to \"Other\" when none is given" do
      changeset = Email.changeset(%Email{}, %{"value" => "a@example.com"})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :email_type) == "Other"
    end

    test "accepts the allowed Work/Personal/Other values" do
      for type <- Email.email_types() do
        changeset = Email.changeset(%Email{}, %{"value" => "a@example.com", "email_type" => type})
        assert changeset.valid?, "expected #{type} to be accepted"
      end
    end

    test "rejects a value outside the allowed set" do
      changeset = Email.changeset(%Email{}, %{"value" => "a@example.com", "email_type" => "Spam"})

      refute changeset.valid?
      assert %{email_type: [_]} = errors_on(changeset)
    end

    test "update_changeset re-labels the type but still guards the allowed set" do
      ok = Email.update_changeset(%Email{email_type: "Other"}, %{"email_type" => "Work"})
      assert ok.valid?
      assert Ecto.Changeset.get_change(ok, :email_type) == "Work"

      bad = Email.update_changeset(%Email{email_type: "Other"}, %{"email_type" => "Nonsense"})
      refute bad.valid?
    end
  end
end
