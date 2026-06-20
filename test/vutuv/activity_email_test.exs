defmodule Vutuv.ActivityEmailTest do
  @moduledoc """
  The opt-in activity notification emails (new follower / endorsement /
  connection request). The in-app push always fires; the email copy is added
  only when the recipient switched the matching preference on (all default
  off), never to the actor themselves, and only to a confirmed account with an
  address.
  """
  use Vutuv.DataCase, async: false
  import Swoosh.TestAssertions

  alias Vutuv.Activity

  # An activated (email_confirmed?) recipient with an email row and the given
  # preferences. The activity emailer looks the address up to decide to send.
  defp recipient(attrs) do
    user = insert(:activated_user, attrs)
    insert(:email, user: user)
    user
  end

  describe "new follower email" do
    test "sent when the recipient opted in, naming the follower by @handle" do
      followee = recipient(email_on_follower?: true)
      follower = insert(:activated_user, username: "ann.actor")

      Activity.notify_new_follower(followee.id, follower)

      assert_email_sent(fn email ->
        assert email.subject =~ "@ann.actor"
        assert email.text_body =~ "following you"
        # Carries a one-click unsubscribe that switches only this type off.
        assert {"List-Unsubscribe-Post", _} =
                 Enum.find(email.headers, &(elem(&1, 0) == "List-Unsubscribe-Post"))
      end)
    end

    test "not sent when the recipient did not opt in (default off)" do
      followee = recipient(email_on_follower?: false)
      Activity.notify_new_follower(followee.id, insert(:activated_user))
      refute_email_sent()
    end

    test "not sent to the actor themselves" do
      me = recipient(email_on_follower?: true)
      Activity.notify_new_follower(me.id, me)
      refute_email_sent()
    end
  end

  describe "endorsement email" do
    test "sent when opted in and names the tag" do
      owner = recipient(email_on_endorsement?: true)
      endorser = insert(:activated_user, username: "ed.actor")

      Activity.notify_endorsement(owner.id, endorser, "Elixir")

      assert_email_sent(fn email ->
        assert email.subject =~ "@ed.actor"
        assert email.text_body =~ "Elixir"
      end)
    end

    test "not sent when not opted in" do
      owner = recipient(email_on_endorsement?: false)
      Activity.notify_endorsement(owner.id, insert(:activated_user), "Elixir")
      refute_email_sent()
    end
  end

  describe "connection (follow-back) email" do
    test "a follow-back sends the new-follower email when opted in" do
      # Vernetzt is a mutual follow; the follow-back is also a new follow, so it
      # reuses the opted-in `email_on_follower?` new-follower email.
      target = recipient(email_on_follower?: true)
      actor = insert(:activated_user, username: "back.actor")

      Activity.notify_connection(target.id, actor)

      assert_email_sent(fn email -> assert email.subject =~ "@back.actor" end)
    end

    test "not sent to an unconfirmed (dormant) recipient even when the flag is set" do
      dormant = insert(:user, email_on_follower?: true)
      insert(:email, user: dormant)
      Activity.notify_connection(dormant.id, insert(:activated_user))
      refute_email_sent()
    end
  end
end
