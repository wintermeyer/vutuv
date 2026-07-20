defmodule Vutuv.Profiles.PhoneNumberTest do
  use Vutuv.DataCase, async: true

  alias Vutuv.Profiles.PhoneNumber

  defp changeset(params) do
    PhoneNumber.changeset(%PhoneNumber{}, Map.merge(%{"value" => "+49 30 12345678"}, params))
  end

  describe "value" do
    test "stores a German number typed in local format in international (E.164) form" do
      cs = changeset(%{"number_type" => "Work", "value" => "0261-123456"})

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :value) == "+49 261 123456"
    end

    test "trims surrounding whitespace before normalizing" do
      cs = changeset(%{"number_type" => "Work", "value" => "  0261-123456  "})

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :value) == "+49 261 123456"
    end

    test "keeps a foreign number on its own country code" do
      cs = changeset(%{"number_type" => "Work", "value" => "+421903419345"})

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :value) == "+421 903 419 345"
    end

    test "rejects a value that is not a real phone number" do
      for bad <- ["12", "555", "not a phone", "+49"] do
        cs = changeset(%{"number_type" => "Work", "value" => bad})

        refute cs.valid?, "expected #{inspect(bad)} to be rejected"
        assert %{value: [_]} = errors_on(cs)
      end
    end
  end

  describe "number_type" do
    test "offers the private/work landline & mobile matrix (issue #948)" do
      assert PhoneNumber.number_types() == ["Home", "Cell", "Work", "Work Cell"]
    end

    test "accepts every offered type" do
      for type <- PhoneNumber.number_types() do
        assert changeset(%{"number_type" => type}).valid?, "expected #{type} to be accepted"
      end
    end

    test "no longer accepts Fax (dropped in #948; legacy rows stay display-only)" do
      cs = changeset(%{"number_type" => "Fax"})

      refute cs.valid?
      assert %{number_type: [_]} = errors_on(cs)
    end

    test "rejects a value outside the allowed set" do
      cs = changeset(%{"number_type" => "mobile"})

      refute cs.valid?
      assert %{number_type: [_]} = errors_on(cs)
    end

    test "still requires a number_type" do
      cs = changeset(%{})

      refute cs.valid?
      assert %{number_type: [_]} = errors_on(cs)
    end
  end
end
