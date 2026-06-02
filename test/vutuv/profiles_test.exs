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

  describe "work_experiences" do
    test "current_job/1 returns the current job" do
      user = insert(:user)
      insert(:work_experience, user: user, start_year: 2020, end_year: nil)
      insert(:work_experience, user: user, start_year: 2015, end_year: 2019)

      job = Profiles.current_job(user)
      assert job.start_year == 2020
      assert job.end_year == nil
    end

    test "current_job/1 returns nil when no work experience" do
      user = insert(:user)
      assert Profiles.current_job(user) == nil
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
