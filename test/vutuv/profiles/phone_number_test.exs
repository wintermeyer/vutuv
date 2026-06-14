defmodule Vutuv.Profiles.PhoneNumberTest do
  use Vutuv.DataCase, async: true

  alias Vutuv.Profiles.PhoneNumber

  defp changeset(params) do
    PhoneNumber.changeset(%PhoneNumber{}, Map.merge(%{"value" => "+49 30 12345678"}, params))
  end

  describe "number_type" do
    test "accepts the allowed Work/Cell/Home/Fax values" do
      for type <- PhoneNumber.number_types() do
        assert changeset(%{"number_type" => type}).valid?, "expected #{type} to be accepted"
      end
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
