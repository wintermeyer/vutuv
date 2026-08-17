defmodule Vutuv.Activity.DigestTest do
  @moduledoc """
  The one way a notification reaches an inbox.

  What is worth guarding here is not one kind's mail but the shape every kind
  shares: shown in the app first, mailed only after it has gone unread for a
  while *and* the member has been away, mailed once, and never mailed at all
  for a kind or a member that did not ask for it.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.Factory

  alias Vutuv.Accounts.User
  alias Vutuv.Activity
  alias Vutuv.Activity.Digest
  alias Vutuv.Repo
  alias Vutuv.Sessions.UserSession
  alias Vutuv.Social.Follow

  setup do
    %{member: mailable_member(), other: insert(:user)}
  end

  # A member the digest can actually reach: confirmed, with an address, and
  # with the kind's own preference on.
  defp mailable_member(prefs \\ [email_on_follower?: true]) do
    user = insert(:user, [email_confirmed?: true] ++ prefs)
    insert(:email, user: user)
    user
  end

  # The digest only looks at events old enough to have been missed, so a test
  # that wants one mailed has to age it past the delay.
  defp aged_follower(member, follower, minutes) do
    at = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -minutes * 60, :second)

    follow = insert(:follow, follower: follower, followee: member)

    Repo.update_all(
      from(f in Follow, where: f.id == ^follow.id),
      set: [inserted_at: at, updated_at: at]
    )

    follow
  end

  defp seen_minutes_ago(user, minutes) do
    Repo.insert!(%UserSession{
      user_id: user.id,
      token_hash: Base.encode16(:crypto.strong_rand_bytes(32)),
      last_seen_at: DateTime.add(DateTime.utc_now(:second), -minutes * 60, :second)
    })
  end

  describe "who gets mailed" do
    test "a member who has been away is mailed what they missed", %{
      member: member,
      other: other
    } do
      aged_follower(member, other, 60)
      seen_minutes_ago(member, 120)

      assert Digest.send_pending() == 1
      assert_received {:email, email}
      assert email.html_body =~ other.username
    end

    # The whole point of the delay: somebody who steps away for a moment and
    # comes back reads it in the app and is never mailed at all.
    test "a member who is still around is not mailed", %{member: member, other: other} do
      aged_follower(member, other, 60)
      seen_minutes_ago(member, 1)

      assert Digest.send_pending() == 0
      refute_received {:email, _email}
    end

    # A notification that only just appeared has not had its chance yet.
    test "a fresh notification waits for the next sweep", %{member: member, other: other} do
      aged_follower(member, other, 1)
      seen_minutes_ago(member, 120)

      assert Digest.send_pending() == 0
    end

    test "reading your notifications is enough to stop the mail", %{
      member: member,
      other: other
    } do
      aged_follower(member, other, 60)
      seen_minutes_ago(member, 120)
      Activity.mark_notifications_read(member.id)

      assert Digest.send_pending() == 0
    end

    # The badge already stays quiet for a vernetzt pair the member completed
    # themselves; a mail about it would be the same alarm with a stamp on it.
    test "a connection the member completed themselves is not mailed", %{
      member: member,
      other: other
    } do
      # `other` followed three hours ago and the member read that in the app,
      # so only what comes after is still mailable.
      aged_follower(member, other, 180)
      Activity.mark_notifications_read(member.id)

      # An hour ago the member followed back. That made the pair vernetzt — by
      # their own hand, so there is nothing left to tell them.
      back = insert(:follow, follower: member, followee: other)
      at = NaiveDateTime.add(NaiveDateTime.utc_now(:second), -60 * 60, :second)
      Repo.update_all(from(f in Follow, where: f.id == ^back.id), set: [inserted_at: at])

      seen_minutes_ago(member, 120)

      assert Digest.send_pending() == 0
      refute_received {:email, _email}
    end

    test "a follow-back from the other side is mailed", %{other: other} do
      member = mailable_member()

      # Mirror image: the member followed first, `other` closed the circle an
      # hour ago. Somebody else acted, so this is news worth a mail.
      insert(:follow, follower: member, followee: other)
      aged_follower(member, other, 60)
      seen_minutes_ago(member, 120)

      assert Digest.send_pending() == 1
      assert_received {:email, _email}
    end
  end

  describe "what the member configured" do
    test "a kind switched off is left out", %{other: other} do
      member = mailable_member(email_on_follower?: false)
      aged_follower(member, other, 60)
      seen_minutes_ago(member, 120)

      assert Digest.send_pending() == 0
    end

    test "the master switch stops all of it", %{other: other} do
      member = mailable_member(email_on_follower?: true, notification_emails?: false)
      aged_follower(member, other, 60)
      seen_minutes_ago(member, 120)

      assert Digest.send_pending() == 0
    end

    test "an unconfirmed address is never mailed", %{other: other} do
      member = insert(:user, email_confirmed?: false, email_on_follower?: true)
      insert(:email, user: member)
      aged_follower(member, other, 60)
      seen_minutes_ago(member, 120)

      assert Digest.send_pending() == 0
    end
  end

  describe "mailed once" do
    test "a second sweep says nothing more", %{member: member, other: other} do
      aged_follower(member, other, 60)
      seen_minutes_ago(member, 120)

      assert Digest.send_pending() == 1
      assert Digest.send_pending() == 0
    end

    # The mark moves past what was mailed, not to "now" — an event that arrived
    # while the mail was being built has not been mailed and must not be lost.
    test "the mark lands on the newest event that was mailed", %{
      member: member,
      other: other
    } do
      aged_follower(member, other, 60)
      seen_minutes_ago(member, 120)

      Digest.send_pending()

      stamped = Repo.get(User, member.id).notifications_notified_at
      assert %DateTime{} = stamped
      assert DateTime.compare(stamped, DateTime.utc_now()) == :lt
    end

    test "something new after the mark is mailed next time", %{member: member, other: other} do
      aged_follower(member, other, 60)
      seen_minutes_ago(member, 120)
      assert Digest.send_pending() == 1

      aged_follower(member, insert(:user), 45)
      assert Digest.send_pending() == 1
    end
  end

  # The registry is the one place a kind is declared, and this is what makes
  # that true for email as well: a kind added without an `email_pref` fails
  # here rather than quietly never reaching anybody.
  describe "the registry" do
    test "every notification kind says whether it may be mailed" do
      prefs = Activity.kind_email_prefs()

      assert map_size(prefs) > 10

      for {kind, pref} <- prefs do
        assert is_nil(pref) or is_atom(pref),
               "#{kind} declares no email_pref in Vutuv.Activity.kind_specs/3"
      end
    end

    test "every declared preference is a real user field" do
      fields = User.__schema__(:fields)

      for {kind, pref} <- Activity.kind_email_prefs(), not is_nil(pref) do
        assert pref in fields, "#{kind} names #{pref}, which is not a user field"
      end
    end
  end
end
