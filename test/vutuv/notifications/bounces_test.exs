defmodule Vutuv.Notifications.BouncesTest do
  @moduledoc """
  Inbound bounce handling: a failure DSN (RFC 3464) marks the bounced address
  undeliverable, `Emailer.deliver/1` then drops automatic mail to it, and a
  successful login PIN through the address clears the mark (delivery
  provably works again).
  """
  use Vutuv.DataCase, async: false
  import Swoosh.TestAssertions

  alias Vutuv.Accounts.Email
  alias Vutuv.Notifications.{Bounces, EmailBounce, Emailer}
  alias Vutuv.Repo

  @failed_dsn """
  Return-Path: <>
  From: MAILER-DAEMON@mail.example.com (Mail Delivery System)
  To: bounces@vutuv.de
  Subject: Undelivered Mail Returned to Sender
  Content-Type: multipart/report; report-type=delivery-status; boundary="ABC"

  --ABC
  Content-Description: Notification
  Content-Type: text/plain; charset=us-ascii

  This is the mail system at host mail.example.com.

  --ABC
  Content-Description: Delivery report
  Content-Type: message/delivery-status

  Reporting-MTA: dns; mail.example.com
  Arrival-Date: Wed, 10 Jun 2026 12:00:00 +0200

  Final-Recipient: rfc822; DEAD@example.com
  Original-Recipient: rfc822;dead@example.com
  Action: failed
  Status: 5.1.1
  Diagnostic-Code: smtp; 550 5.1.1 User unknown

  --ABC--
  """

  # Same shape as @failed_dsn but a policy rejection (DMARC/authentication),
  # not a dead mailbox: must NOT deactivate a live address.
  @policy_failed_dsn """
  From: MAILER-DAEMON@mail.example.com (Mail Delivery System)
  Content-Type: multipart/report; report-type=delivery-status; boundary="ABC"

  --ABC
  Content-Type: message/delivery-status

  Final-Recipient: rfc822; dead@example.com
  Action: failed
  Status: 5.7.1
  Diagnostic-Code: smtp; 550 5.7.1 Message rejected by DMARC policy

  --ABC--
  """

  # A give-up on a transient failure (4.x): the MTA stopped, but this is not a
  # recipient failure, so it must NOT deactivate a live address either.
  @transient_failed_dsn """
  From: MAILER-DAEMON@mail.example.com (Mail Delivery System)
  Content-Type: multipart/report; report-type=delivery-status; boundary="ABC"

  --ABC
  Content-Type: message/delivery-status

  Final-Recipient: rfc822; dead@example.com
  Action: failed
  Status: 4.4.7
  Diagnostic-Code: smtp; 450 4.4.7 Delivery time expired

  --ABC--
  """

  @delayed_dsn """
  From: MAILER-DAEMON@mail.example.com (Mail Delivery System)
  Subject: Delayed Mail (still being retried)
  Content-Type: multipart/report; report-type=delivery-status; boundary="X"

  --X
  Content-Type: message/delivery-status

  Final-Recipient: rfc822; slow@example.com
  Action: delayed
  Status: 4.4.1

  --X--
  """

  setup do
    Vutuv.RateLimiter.reset()
    :ok
  end

  defp user_with_email(address) do
    user = insert(:activated_user)
    insert(:email, user: user, value: address)
    {user, Repo.get_by!(Email, value: address)}
  end

  defp reload(%Email{} = email), do: Repo.get!(Email, email.id)

  describe "record/1" do
    test "a failure DSN marks the address undeliverable and is logged" do
      {_user, email} = user_with_email("dead@example.com")

      assert {:ok, :failed} = Bounces.record(@failed_dsn)

      assert reload(email).undeliverable_at
      assert [bounce] = Repo.all(EmailBounce)
      # The DSN names the recipient in upper case; addresses are stored lowercase.
      assert bounce.email_value == "dead@example.com"
      assert bounce.action == "failed"
      assert bounce.status == "5.1.1"
      assert bounce.raw =~ "User unknown"
    end

    test "a failure for an address we do not know is still recorded" do
      assert {:ok, :failed} = Bounces.record(@failed_dsn)
      assert [%EmailBounce{email_value: "dead@example.com"}] = Repo.all(EmailBounce)
    end

    test "a policy failure (5.7.x) is recorded but does NOT deactivate the address" do
      {_user, email} = user_with_email("dead@example.com")

      assert {:ok, :ignored} = Bounces.record(@policy_failed_dsn)

      # A DMARC/authentication rejection is not a dead mailbox: the live
      # address stays deliverable, matching the log watcher's classification.
      assert reload(email).undeliverable_at == nil
      assert Repo.all(EmailBounce) == []
    end

    test "a transient failure (4.x) is ignored, not deactivated" do
      {_user, email} = user_with_email("dead@example.com")

      assert {:ok, :ignored} = Bounces.record(@transient_failed_dsn)

      assert reload(email).undeliverable_at == nil
      assert Repo.all(EmailBounce) == []
    end

    test "a delay DSN is ignored (Postfix is still retrying)" do
      {_user, email} = user_with_email("slow@example.com")

      assert {:ok, :ignored} = Bounces.record(@delayed_dsn)

      assert reload(email).undeliverable_at == nil
      assert Repo.all(EmailBounce) == []
    end

    test "garbage is rejected" do
      assert {:error, :unparseable} = Bounces.record("To: whatever\n\nnot a DSN")
    end
  end

  describe "suppression in Emailer.deliver/1" do
    test "automatic mail to an undeliverable address is dropped" do
      {user, email} = user_with_email("dead@example.com")
      {:ok, _} = Bounces.record(@failed_dsn)
      other = insert(:user)

      result =
        "dead@example.com"
        |> Emailer.unread_messages_email(user, other, Vutuv.UUIDv7.generate(), "hi")
        |> Emailer.deliver()

      assert result == :suppressed
      refute_email_sent()
      assert reload(email).undeliverable_at
    end

    test "user-initiated PIN mail still goes out (the way back in must stay open)" do
      {user, _email} = user_with_email("dead@example.com")
      {:ok, _} = Bounces.record(@failed_dsn)

      "123456"
      |> Emailer.login_email("dead@example.com", user)
      |> Emailer.deliver()

      assert_email_sent(fn sent ->
        assert [{_name, "dead@example.com"}] = sent.to
      end)
    end

    test "mail to a healthy address is unaffected" do
      {user, _email} = user_with_email("fine@example.com")
      other = insert(:user)

      "fine@example.com"
      |> Emailer.unread_messages_email(user, other, Vutuv.UUIDv7.generate(), "hi")
      |> Emailer.deliver()

      assert_email_sent()
    end
  end

  describe "clear/1" do
    test "a successful login PIN through the address clears the mark" do
      {_user, email} = user_with_email("dead@example.com")
      {:ok, _} = Bounces.record(@failed_dsn)
      assert reload(email).undeliverable_at

      conn = Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})
      {:ok, _conn} = Vutuv.Accounts.login_by_email(conn, "dead@example.com")
      assert_received {:email, pin_email}
      [pin] = Regex.run(~r/\b\d{6}\b/, pin_email.text_body)

      assert {:ok, _user} = Vutuv.Accounts.check_pin("dead@example.com", pin, "login")

      assert reload(email).undeliverable_at == nil
    end

    test "a wrong PIN does not clear the mark" do
      {_user, email} = user_with_email("dead@example.com")
      {:ok, _} = Bounces.record(@failed_dsn)

      conn = Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})
      {:ok, _conn} = Vutuv.Accounts.login_by_email(conn, "dead@example.com")

      assert {:error, _} = Vutuv.Accounts.check_pin("dead@example.com", "000000", "login")
      assert reload(email).undeliverable_at
    end
  end
end
