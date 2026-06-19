defmodule Vutuv.Profiles.AddressTest do
  use Vutuv.DataCase, async: true

  alias Vutuv.Profiles.Address

  defp changeset(params) do
    base = %{"description" => "Home", "country" => "Germany"}
    Address.changeset(%Address{}, Map.merge(base, params))
  end

  test "accepts a normal address" do
    assert changeset(%{"line_1" => "Marktplatz 1", "city" => "Koblenz"}).valid?
  end

  test "still requires description and country" do
    cs = Address.changeset(%Address{}, %{})

    refute cs.valid?
    errors = errors_on(cs)
    assert errors[:description]
    assert errors[:country]
  end

  test "rejects an over-long line" do
    cs = changeset(%{"line_1" => String.duplicate("x", 256)})

    refute cs.valid?
    assert %{line_1: [_]} = errors_on(cs)
  end

  test "rejects an over-long country" do
    cs = changeset(%{"country" => String.duplicate("x", 101)})

    refute cs.valid?
    assert %{country: [_]} = errors_on(cs)
  end
end
