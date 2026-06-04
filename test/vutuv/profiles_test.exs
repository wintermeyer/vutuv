defmodule Vutuv.ProfilesTest do
  use Vutuv.DataCase

  alias Vutuv.Profiles

  describe "addresses" do
    test "create_address/2 creates an address" do
      user = insert(:user)

      assert {:ok, address} =
               Profiles.create_address(user, %{description: "Home", country: "Germany"})

      assert address.description == "Home"
      assert address.user_id == user.id
    end

    test "list_addresses/1 returns user's addresses" do
      user = insert(:user)
      insert(:address, user: user)
      assert length(Profiles.list_addresses(user)) == 1
    end
  end

  describe "count_user_assoc/2" do
    test "returns the count of associated records" do
      user = insert(:user)
      insert(:address, user: user)
      insert(:address, user: user)
      assert Profiles.count_user_assoc(user, :addresses) == 2
    end
  end
end
