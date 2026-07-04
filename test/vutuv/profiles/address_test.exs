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

  test "trims leading and trailing whitespace from the fields" do
    # A stray space here is what rendered "50679  Köln" (double space) once
    # the zip and city were joined for the CV and other address surfaces.
    cs = changeset(%{"zip_code" => "50679 ", "city" => " Köln"})

    assert cs.valid?
    assert Ecto.Changeset.get_change(cs, :zip_code) == "50679"
    assert Ecto.Changeset.get_change(cs, :city) == "Köln"
  end

  test "collapses a whitespace-only value to nil, so required still bites" do
    cs = Address.changeset(%Address{}, %{"description" => "Home", "country" => "   "})

    refute cs.valid?
    assert errors_on(cs)[:country]
  end

  test "trims before the length check, so a padded max-length value passes" do
    padded = " " <> String.duplicate("x", 255) <> " "
    cs = changeset(%{"line_1" => padded})

    assert cs.valid?
    assert Ecto.Changeset.get_change(cs, :line_1) == String.duplicate("x", 255)
  end
end
