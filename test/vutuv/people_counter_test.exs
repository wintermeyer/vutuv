defmodule Vutuv.PeopleCounterTest do
  # async: false — the increment/count assertions read the process-global
  # counter before and after, so no other test may register a user in between.
  use Vutuv.DataCase, async: false

  alias Vutuv.Accounts
  alias Vutuv.Fediverse.Follower
  alias Vutuv.PeopleCounter

  @valid_registration %{
    "emails" => %{"0" => %{"value" => "counted@example.com"}},
    "first_name" => "Counted",
    "last_name" => "Member",
    "tag_list" => "Elixir, Cooking, Origami"
  }

  defp build_conn do
    %Plug.Conn{
      assigns: %{locale: "en"},
      private: %{plug_session: %{}, plug_session_fetch: :done}
    }
    |> Plug.Test.init_test_session(%{})
  end

  defp members, do: PeopleCounter.counts().members

  describe "the lock-free counter" do
    test "increment/0 bumps the member half by one without touching the database" do
      before = members()

      assert :ok = PeopleCounter.increment()

      assert members() == before + 1
    end

    test "an unconfirmed sign-up does not tick the counter; confirming it does (issue #781)" do
      before = members()

      assert {:ok, user} = Accounts.register_user(build_conn(), @valid_registration)
      # The advertised total counts confirmed members, so a sign-up that has not
      # confirmed its PIN must not move the live counter.
      assert members() == before
      refute user.email_confirmed?

      # First login confirms the account (email_confirmed? false -> true) and counts it.
      Accounts.login(build_conn(), user)
      assert members() == before + 1
    end

    test "a returning login of an already-confirmed member does not re-count" do
      user = insert(:activated_user)
      before = members()

      Accounts.login(build_conn(), user)

      assert members() == before
    end

    test "a legacy nil-activated account is not re-counted when it logs in" do
      user = insert(:user, email_confirmed?: nil)
      before = members()

      Accounts.login(build_conn(), user)

      assert members() == before
    end
  end

  describe "members leaving" do
    test "deleting a confirmed member ticks the live total back down" do
      user = insert(:activated_user)
      # The factory writes the row straight to the database, so count the member
      # the way a real confirmation would before deleting them again.
      PeopleCounter.increment()
      before = members()

      assert {:ok, _user} = Accounts.delete_user(user)

      assert members() == before - 1
    end

    test "deleting a legacy nil-activated account ticks the total down too" do
      user = insert(:user, email_confirmed?: nil)
      PeopleCounter.increment()
      before = members()

      assert {:ok, _user} = Accounts.delete_user(user)

      assert members() == before - 1
    end

    test "deleting an abandoned sign-up leaves the total alone" do
      # An unconfirmed registration was never in the advertised total (it only
      # counts confirmed accounts), and the abandoned-sign-up sweep deletes it
      # through this same function — so its deletion must not tick anything down.
      user = insert(:user, email_confirmed?: false)
      PeopleCounter.increment()
      before = members()

      assert {:ok, _user} = Accounts.delete_user(user)

      assert members() == before
    end

    test "decrement/0 stops at zero instead of wrapping the unsigned cell around" do
      # Zero is only reachable in the sub-second before the first reconcile
      # seeds the cell, but an unsigned atomic wraps to 2^64-1 on a subtraction
      # that would go negative, so without the guard one stray delete would
      # advertise eighteen quintillion people. This module is synchronous, so
      # draining and refilling the process-global cell is safe here.
      start = members()
      for _ <- 1..start//1, do: PeopleCounter.decrement()
      assert members() == 0

      assert :ok = PeopleCounter.decrement()
      assert members() == 0

      for _ <- 1..start//1, do: PeopleCounter.increment()
      assert members() == start
    end
  end

  describe "the broadcasting owner process" do
    # An isolated instance with its own atomic cell and topic, so it neither
    # disturbs nor depends on the application-wide singleton.
    setup do
      ref = :atomics.new(2, signed: false)
      topic = "people_count:test:#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          {PeopleCounter,
           name: nil,
           ref: ref,
           topic: topic,
           register?: false,
           reconcile?: false,
           broadcast?: true,
           broadcast_interval: 30}
        )

      Phoenix.PubSub.subscribe(Vutuv.PubSub, topic)
      %{ref: ref, topic: topic, pid: pid}
    end

    test "coalesces a burst of increments into a single broadcast of the latest value", %{
      ref: ref
    } do
      # Three "sign-ups" land before the first broadcast tick fires.
      :atomics.add(ref, 1, 1)
      :atomics.add(ref, 1, 1)
      :atomics.add(ref, 1, 1)

      assert_receive {:people_count, %{members: 3, fediverse: 0, total: 3}}, 500

      # While the value is stable it stops broadcasting — no per-tick spam.
      refute_receive {:people_count, _}, 100
    end

    test "broadcasts again when the value changes", %{ref: ref} do
      :atomics.add(ref, 1, 1)
      assert_receive {:people_count, %{total: 1}}, 500

      :atomics.add(ref, 1, 1)
      assert_receive {:people_count, %{total: 2}}, 500
    end

    test "a Fediverse account arriving moves the total on its own", %{ref: ref} do
      :atomics.add(ref, 1, 2)
      assert_receive {:people_count, %{members: 2, fediverse: 0, total: 2}}, 500

      # The second slot is the distinct Fediverse head count; the pill adds the
      # two halves, so a remote Follow ticks the same figure a sign-up does.
      :atomics.add(ref, 2, 1)
      assert_receive {:people_count, %{members: 2, fediverse: 1, total: 3}}, 500
    end
  end

  describe "reconciling from the database" do
    test "seeds both halves and advertises their sum" do
      users = insert_list(3, :activated_user)

      # One remote account following two of those members: two follower rows,
      # one person. A row count would advertise four people here.
      for user <- Enum.take(users, 2) do
        Repo.insert!(%Follower{
          user_id: user.id,
          actor_uri: "https://remote.example/users/frida",
          inbox_uri: "https://remote.example/users/frida/inbox"
        })
      end

      ref = :atomics.new(2, signed: false)
      topic = "people_count:reconcile:#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Vutuv.PubSub, topic)

      start_supervised!(
        {PeopleCounter,
         name: nil,
         ref: ref,
         topic: topic,
         register?: false,
         reconcile?: true,
         broadcast?: true,
         reconcile_interval: 60_000,
         fediverse_interval: 60_000,
         broadcast_interval: 30}
      )

      assert_receive {:people_count, %{members: 3, fediverse: 1, total: 4}}, 1000
    end
  end
end
