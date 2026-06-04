defmodule Vutuv.ActivityTest do
  use ExUnit.Case, async: true

  alias Vutuv.Activity

  test "notify broadcasts a :new_notification to the user topic" do
    Activity.subscribe(42)
    Activity.notify(42, %{kind: "follower", text: "Hi"})
    assert_receive {:new_notification, %{text: "Hi"}}
  end

  test "notify_new_follower carries the actor's name and action" do
    Activity.subscribe(7)
    Activity.notify_new_follower(7, %{first_name: "José", last_name: "Daniel"})

    assert_receive {:new_notification,
                    %{kind: "follower", actor_name: "José Daniel", text: "started following you."} =
                      n}

    # A bare map (not a %User{}) has no profile to link or avatar to show.
    assert n.actor_param == nil
    assert n.actor_avatar == nil
  end

  test "a nil recipient is a no-op (no crash, nothing delivered)" do
    Activity.subscribe(13)
    assert :ok = Activity.notify(nil, %{text: "ignored"})
    refute_receive {:new_notification, _}
  end

  test "mark_notifications_read / mark_messages_read broadcast read events" do
    Activity.subscribe(9)
    Activity.mark_notifications_read(9)
    Activity.mark_messages_read(9)
    assert_receive :notifications_read
    assert_receive :messages_read
  end
end
