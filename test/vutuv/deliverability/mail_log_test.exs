defmodule Vutuv.Deliverability.MailLogTest do
  @moduledoc """
  The pure Postfix-log parser: attribute delivery results to vutuv by joining
  the recipient line's queue-id back to a `from=<bounces@vutuv.de>` line, and
  classify the DSN code (dead recipient vs policy vs transient). Sample lines
  are real shapes taken from the production `mail.log` (a multi-tenant relay).
  """
  use ExUnit.Case, async: true

  alias Vutuv.Deliverability.MailLog

  # A vutuv message to a dead mailbox: envelope line, then the bounce.
  @vutuv_hard_bounce [
    "2026-06-19T11:13:09 bremen2 postfix/qmgr[2473331]: AAAA1111: from=<bounces@vutuv.de>, size=1177, nrcpt=1 (queue active)",
    "2026-06-19T11:13:10 bremen2 postfix/smtp[948014]: AAAA1111: to=<dead@example.com>, relay=mx.example.com[1.2.3.4]:25, delay=1, dsn=5.1.1, status=bounced (host mx.example.com said: 550 5.1.1 User unknown)"
  ]

  # Another tenant on the same relay bouncing - must NOT be attributed to us.
  @other_tenant_bounce [
    "2026-06-19T11:14:00 bremen2 postfix/qmgr[3431]: BBBB2222: from=<noreply@mehr-schulferien.de>, size=2665, nrcpt=1 (queue active)",
    "2026-06-19T11:14:01 bremen2 postfix/smtp[948]: BBBB2222: to=<someone@gmail.com>, relay=gmail-smtp-in.l.google.com[1.2.3.4]:25, dsn=5.7.26, status=bounced (host gmail said: 550-5.7.26 unauthenticated)"
  ]

  describe "reduce/2 attribution" do
    test "a vutuv hard bounce is ours and classified hard_bounce" do
      {[event], _state} = MailLog.reduce(@vutuv_hard_bounce, MailLog.new())

      assert event.queue_id == "AAAA1111"
      assert event.to == "dead@example.com"
      assert event.dsn == "5.1.1"
      assert event.status == "bounced"
      assert event.class == :hard_bounce
      assert event.ours?
    end

    test "another tenant's bounce on the same relay is not ours" do
      {[event], _state} = MailLog.reduce(@other_tenant_bounce, MailLog.new())

      assert event.to == "someone@gmail.com"
      refute event.ours?
      # And it is a policy bounce, never a dead-recipient signal.
      assert event.class == :policy
    end

    test "interleaved tenants are attributed independently" do
      {events, _state} =
        MailLog.reduce(@vutuv_hard_bounce ++ @other_tenant_bounce, MailLog.new())

      assert [%{to: "dead@example.com", ours?: true}, %{to: "someone@gmail.com", ours?: false}] =
               events
    end

    test "a delivery whose envelope was never seen is not ours" do
      orphan = [List.last(@vutuv_hard_bounce)]
      {[event], _state} = MailLog.reduce(orphan, MailLog.new())
      refute event.ours?
    end

    test "attribution survives across batches via carried state" do
      [envelope, delivery] = @vutuv_hard_bounce
      {[], state} = MailLog.reduce([envelope], MailLog.new())
      {[event], _state} = MailLog.reduce([delivery], state)
      assert event.ours?
    end

    test "non-delivery lines are ignored" do
      noise = [
        "2026-06-19T11:13:11 bremen2 postfix/qmgr[2473331]: AAAA1111: removed",
        "2026-06-19T11:13:12 bremen2 postfix/cleanup[1]: AAAA1111: message-id=<x@bremen2>"
      ]

      assert {[], _state} = MailLog.reduce(noise, MailLog.new())
    end

    test "a quoted local-part recipient is parsed and downcased" do
      lines = [
        "postfix/qmgr[1]: CC334455: from=<bounces@vutuv.de>, size=1",
        "postfix/smtp[1]: CC334455: to=<\"Weird.Local\"@gmail.com>, dsn=5.1.3, status=bounced (553 invalid)"
      ]

      {[event], _state} = MailLog.reduce(lines, MailLog.new())
      assert event.to == "\"weird.local\"@gmail.com"
      assert event.class == :hard_bounce
      assert event.ours?
    end
  end

  describe "classify/2" do
    test "delivered and transient" do
      assert MailLog.classify("sent", "2.0.0") == :delivered
      assert MailLog.classify("deferred", "4.0.0") == :transient
      assert MailLog.classify("bounced", "4.4.1") == :transient
    end

    test "hard recipient failures" do
      for dsn <- ~w(5.0.0 5.1.1 5.1.2 5.1.3 5.5.0) do
        assert MailLog.classify("bounced", dsn) == :hard_bounce, "#{dsn} should be hard"
      end
    end

    test "policy / authentication bounces are not recipient failures" do
      assert MailLog.classify("bounced", "5.7.26") == :policy
      assert MailLog.classify("bounced", "5.7.1") == :policy
    end

    test "ambiguous 5.x bounces are left alone" do
      assert MailLog.classify("bounced", "5.2.2") == :other
      assert MailLog.classify("bounced", "5.4.4") == :other
    end
  end

  describe "recipient_failure?/1" do
    test "true only for the recipient-failure families" do
      assert MailLog.recipient_failure?("5.1.1")
      assert MailLog.recipient_failure?("5.5.0")
      assert MailLog.recipient_failure?("5.0.0")
      refute MailLog.recipient_failure?("5.7.26")
      refute MailLog.recipient_failure?("5.2.2")
      refute MailLog.recipient_failure?("4.0.0")
    end
  end
end
