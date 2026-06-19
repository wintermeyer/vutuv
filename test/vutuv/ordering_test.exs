defmodule Vutuv.OrderingTest do
  use Vutuv.DataCase, async: true

  alias Vutuv.Ordering
  alias Vutuv.Profiles.PhoneNumber
  alias Vutuv.Profiles.Url

  setup do
    %{user: insert_activated_user()}
  end

  describe "by_position/1" do
    test "orders by position (NULLs last), then id", %{user: user} do
      late = insert(:url, user: user, position: 2)
      early = insert(:url, user: user, position: 1)
      legacy = insert(:url, user: user, position: nil)

      ids = Repo.all(from(u in Url.ordered(Ecto.assoc(user, :urls)), select: u.id))

      assert ids == [early.id, late.id, legacy.id]
    end
  end

  describe "next_position/2" do
    test "is 1 for a member with no rows yet", %{user: user} do
      assert Ordering.next_position(PhoneNumber, user.id) == 1
    end

    test "is max + 1 otherwise", %{user: user} do
      insert(:phone_number, user: user, position: 4)
      assert Ordering.next_position(PhoneNumber, user.id) == 5
    end
  end

  describe "reorder/3" do
    test "persists the submitted order as positions 1..n", %{user: user} do
      a = insert(:url, user: user, position: 1)
      b = insert(:url, user: user, position: 2)
      c = insert(:url, user: user, position: 3)

      Ordering.reorder(Url, user.id, [c.id, a.id, b.id])

      assert Repo.get(Url, c.id).position == 1
      assert Repo.get(Url, a.id).position == 2
      assert Repo.get(Url, b.id).position == 3
    end

    test "drops foreign ids and never touches another member's rows", %{user: user} do
      mine = insert(:url, user: user, position: 1)
      other = insert_activated_user()
      theirs = insert(:url, user: other, position: 1)

      Ordering.reorder(Url, user.id, [theirs.id, mine.id])

      assert Repo.get(Url, theirs.id).position == 1
      assert Repo.get(Url, mine.id).position == 1
    end

    test "appends ids the client omitted, keeping a clean 1..n", %{user: user} do
      a = insert(:url, user: user, position: 1)
      b = insert(:url, user: user, position: 2)

      Ordering.reorder(Url, user.id, [b.id])

      assert Repo.get(Url, b.id).position == 1
      assert Repo.get(Url, a.id).position == 2
    end
  end

  describe "move/4" do
    test "up swaps a row with its predecessor", %{user: user} do
      a = insert(:url, user: user, position: 1)
      b = insert(:url, user: user, position: 2)

      Ordering.move(Url, user.id, b.id, :up)

      assert Repo.get(Url, b.id).position == 1
      assert Repo.get(Url, a.id).position == 2
    end

    test "down at the bottom is a no-op", %{user: user} do
      a = insert(:url, user: user, position: 1)
      b = insert(:url, user: user, position: 2)

      Ordering.move(Url, user.id, b.id, :down)

      assert Repo.get(Url, a.id).position == 1
      assert Repo.get(Url, b.id).position == 2
    end
  end
end
