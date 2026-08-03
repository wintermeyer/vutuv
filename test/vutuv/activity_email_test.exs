defmodule Vutuv.ActivityEmailTest do
  @moduledoc """
  What `Vutuv.Activity` itself sends: **nothing**.

  Every notification kind now reaches an inbox through one path — the digest
  sweeper (`Vutuv.Activity.Digest`, covered by `activity_digest_test.exs`) —
  and only for a member who was away long enough to have missed it in the app.
  These kinds used to mail the instant they happened, which meant a member
  reading their notifications was mailed about the row they were looking at.

  So what is worth guarding here is the absence: the in-app push still fires,
  and no mail follows it. The preferences these tests set still matter, but
  they are read by the sweeper now, which is where they are tested.
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
    # Opted in or not, nothing leaves here: the preference decides whether the
    # digest may carry this kind later, not whether a mail goes now.
    test "no mail follows the notification, even for a member who opted in" do
      followee = recipient(email_on_follower?: true)
      follower = insert(:activated_user, username: "ann.actor")

      Activity.notify_new_follower(followee.id, follower)

      refute_email_sent()
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
    test "no mail follows the notification, even for a member who opted in" do
      owner = recipient(email_on_endorsement?: true)
      endorser = insert(:activated_user, username: "ed.actor")

      Activity.notify_endorsement(owner.id, endorser, "Elixir")

      refute_email_sent()
    end

    test "not sent when not opted in" do
      owner = recipient(email_on_endorsement?: false)
      Activity.notify_endorsement(owner.id, insert(:activated_user), "Elixir")
      refute_email_sent()
    end
  end

  describe "connection (follow-back) email" do
    test "no mail follows a follow-back either" do
      # Vernetzt is a mutual follow; the follow-back is also a new follow, so it
      # reuses the opted-in `email_on_follower?` new-follower email.
      target = recipient(email_on_follower?: true)
      actor = insert(:activated_user, username: "back.actor")

      Activity.notify_connection(target.id, actor)

      refute_email_sent()
    end

    test "not sent to an unconfirmed (dormant) recipient even when the flag is set" do
      dormant = insert(:user, email_on_follower?: true)
      insert(:email, user: dormant)
      Activity.notify_connection(dormant.id, insert(:activated_user))
      refute_email_sent()
    end
  end
end
