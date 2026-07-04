defmodule Vutuv.LegalTest do
  use Vutuv.DataCase, async: true

  alias Vutuv.Legal
  alias Vutuv.Legal.LegalPage

  describe "slugs/0" do
    test "names the three fixed legal pages" do
      assert Legal.slugs() == ~w(impressum datenschutzerklaerung nutzungsbedingungen)
    end
  end

  describe "get_page/1" do
    test "returns nil while the operator has not written the page yet" do
      assert Legal.get_page("impressum") == nil
    end

    test "returns the stored page" do
      {:ok, _page} = Legal.upsert_page("impressum", %{body: "**Acme GmbH**"})

      assert %LegalPage{slug: "impressum", body: "**Acme GmbH**"} = Legal.get_page("impressum")
    end

    test "returns nil for an unknown slug" do
      assert Legal.get_page("robots") == nil
    end
  end

  describe "upsert_page/2" do
    test "creates the page on first save and updates it afterwards" do
      {:ok, created} = Legal.upsert_page("datenschutzerklaerung", %{body: "Erste Fassung"})
      {:ok, updated} = Legal.upsert_page("datenschutzerklaerung", %{body: "Zweite Fassung"})

      assert created.id == updated.id
      assert Legal.get_page("datenschutzerklaerung").body == "Zweite Fassung"
    end

    test "requires a body" do
      assert {:error, changeset} = Legal.upsert_page("impressum", %{body: ""})
      assert %{body: [_reason]} = errors_on(changeset)
    end

    test "caps the body length" do
      too_long = String.duplicate("a", 100_001)

      assert {:error, changeset} = Legal.upsert_page("impressum", %{body: too_long})
      assert %{body: [_reason]} = errors_on(changeset)
    end

    test "refuses an unknown slug" do
      assert {:error, changeset} = Legal.upsert_page("robots", %{body: "nope"})
      assert %{slug: [_reason]} = errors_on(changeset)
    end
  end
end
