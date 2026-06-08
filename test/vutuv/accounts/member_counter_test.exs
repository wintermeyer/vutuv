defmodule Vutuv.Accounts.MemberCounterTest do
  # async: false — the increment/count assertions read the process-global
  # counter before and after, so no other test may register a user in between.
  use Vutuv.DataCase, async: false

  alias Vutuv.Accounts
  alias Vutuv.Accounts.MemberCounter

  @valid_registration %{
    "emails" => %{"0" => %{"value" => "counted@example.com"}},
    "first_name" => "Counted",
    "last_name" => "Member"
  }

  defp build_conn do
    %Plug.Conn{
      assigns: %{locale: "en"},
      private: %{plug_session: %{}, plug_session_fetch: :done}
    }
    |> Plug.Test.init_test_session(%{})
  end

  describe "the lock-free counter" do
    test "increment/0 bumps count/0 by one without touching the database" do
      before = MemberCounter.count()

      assert :ok = MemberCounter.increment()

      assert MemberCounter.count() == before + 1
    end

    test "registering a user increments the live member count" do
      before = MemberCounter.count()

      assert {:ok, _user} = Accounts.register_user(build_conn(), @valid_registration)

      assert MemberCounter.count() == before + 1
    end
  end

  describe "the broadcasting owner process" do
    # An isolated instance with its own atomic cell and topic, so it neither
    # disturbs nor depends on the application-wide singleton.
    setup do
      ref = :atomics.new(1, signed: false)
      topic = "member_count:test:#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          {MemberCounter,
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

      assert_receive {:member_count, 3}, 500

      # While the value is stable it stops broadcasting — no per-tick spam.
      refute_receive {:member_count, _}, 100
    end

    test "broadcasts again when the value changes", %{ref: ref} do
      :atomics.add(ref, 1, 1)
      assert_receive {:member_count, 1}, 500

      :atomics.add(ref, 1, 1)
      assert_receive {:member_count, 2}, 500
    end
  end

  describe "reconciling from the database" do
    test "seeds the cell from the authoritative user count" do
      insert_list(3, :user)

      ref = :atomics.new(1, signed: false)
      topic = "member_count:reconcile:#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Vutuv.PubSub, topic)

      start_supervised!(
        {MemberCounter,
         name: nil,
         ref: ref,
         topic: topic,
         register?: false,
         reconcile?: true,
         broadcast?: true,
         reconcile_interval: 60_000,
         broadcast_interval: 30}
      )

      assert_receive {:member_count, 3}, 1000
    end
  end
end
