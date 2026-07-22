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

    test "hard recipient failures (enhanced-code families)" do
      for dsn <- ~w(5.1.1 5.1.2 5.1.3 5.5.0) do
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

  # `5.0.0` is not an enhanced code from the remote: it is Postfix's mapping
  # for a bare 550/552 reply, so it also carries full mailboxes and
  # recipient-side blocks. Only the reply text can tell them apart. All sample
  # texts below are real shapes from the production mail.log (issue: 19
  # members were frozen over quota/blocked replies miscounted as dead).
  describe "classify/3 vets the generic 5.0.x bucket by reply text" do
    test "a full mailbox (552 quota without an enhanced code) is left alone" do
      text =
        "host mx01.emig.gmx.net[212.227.17.5] said: 552-Requested mail action aborted: " <>
          "exceeded storage allocation 552-Quota exceeded"

      assert MailLog.classify("bounced", "5.0.0", text) == :other
    end

    test "a recipient-side block is a policy problem, not a dead recipient" do
      barracuda =
        "host eu.bar.example said: 550 permanent failure for one or more recipients " <>
          "(dhanneke@example.com:blocked) (in reply to end of DATA command)"

      fakemail =
        "host mx.example said: 550 Your IP or Email address blocked by the FakeMail User."

      multi_cause =
        "host mx.example said: 550-The mail server could not deliver mail to x@y. " <>
          "550-The account or domain may not 550 exist, they may be blacklisted, or missing."

      for text <- [barracuda, fakemail, multi_cause] do
        assert MailLog.classify("bounced", "5.0.0", text) == :policy
      end
    end

    test "reply text confirming a dead recipient stays a hard bounce" do
      confirmations = [
        "host mx00.ionos.de[212.227.15.41] said: 550-Requested action not taken: mailbox unavailable",
        "host mta6.am0.yahoodns.net said: 552 1 Requested mail action aborted, mailbox not found",
        "host mx.example said: 550 No mailbox by that name is currently available",
        "host eu-smtp-inbound-1.mimecast.com said: 550 Invalid Recipient - https://example.com",
        "host smtp.secureserver.net said: 550 5.1.0 <x@y> Recipient not found.",
        "host mx.example said: 550 User unknown",
        "host mailin.ng.telekom.net[3.71.246.67] said: 550 #5.1.0 Address rejected.",
        "host mx.example said: 550 Unroutable address",
        "host mx.example said: 550 unrouteable address",
        "host mx.example said: 550 Address unknown",
        "host mx.example said: 550 MXIN501 mailbox marco.abderhalden@example.ch unknown ;id=x"
      ]

      for text <- confirmations do
        assert MailLog.classify("bounced", "5.0.0", text) == :hard_bounce, text
      end
    end

    test "only the remote's reply is vetted, never relay hostnames on the log line" do
      # Real trap from prod: the relay is mx10.mailspamprotection.com - "spam"
      # in the hostname must not turn a dead-recipient reply into :policy.
      line =
        "2026-07-01T13:02:01 bremen2 postfix/smtp[2817771]: 5DF1E3A80864: " <>
          "to=<miriam@example.com>, relay=mx10.mailspamprotection.com[34.149.79.66]:25, " <>
          "dsn=5.0.0, status=bounced (host mx10.mailspamprotection.com[34.149.79.66] said: " <>
          "550 No mailbox by that name is currently available (in reply to RCPT TO command))"

      assert MailLog.classify("bounced", "5.0.0", line) == :hard_bounce
      assert MailLog.recipient_failure?("5.0.0", line)
    end

    test "a sender-verification rejection is never a dead recipient" do
      assert MailLog.classify(
               "bounced",
               "5.0.0",
               "host mx.example said: 550 Sender address rejected: domain not found"
             ) == :policy
    end

    test "an unrecognized 5.0.x reply text is conservatively left alone" do
      assert MailLog.classify("bounced", "5.0.0", "550 something entirely novel") == :other
      assert MailLog.classify("bounced", "5.0.0") == :other
    end

    test "an enhanced recipient-failure code stays authoritative over its text" do
      assert MailLog.classify("bounced", "5.1.1", "552 Quota exceeded") == :hard_bounce
    end

    test "the vetted class flows through reduce/2, so the watcher never acts on quota" do
      quota_lines = [
        "postfix/qmgr[1]: DD445566: from=<bounces@vutuv.de>, size=1",
        "postfix/smtp[1]: DD445566: to=<full@gmx.de>, relay=mx.gmx.net[1.2.3.4]:25, dsn=5.0.0, " <>
          "status=bounced (host mx.gmx.net said: 552-Quota exceeded)"
      ]

      {[event], _state} = MailLog.reduce(quota_lines, MailLog.new())
      assert event.ours?
      assert event.class == :other

      dead_lines = [
        "postfix/qmgr[1]: EE556677: from=<bounces@vutuv.de>, size=1",
        "postfix/smtp[1]: EE556677: to=<gone@ionos.de>, relay=mx00.ionos.de[1.2.3.4]:25, dsn=5.0.0, " <>
          "status=bounced (host mx00.ionos.de said: 550-Requested action not taken: mailbox unavailable)"
      ]

      {[event], _state} = MailLog.reduce(dead_lines, MailLog.new())
      assert event.ours?
      assert event.class == :hard_bounce
    end
  end

  describe "recipient_failure?/2" do
    test "true only for the recipient-failure families" do
      assert MailLog.recipient_failure?("5.1.1")
      assert MailLog.recipient_failure?("5.5.0")
      refute MailLog.recipient_failure?("5.7.26")
      refute MailLog.recipient_failure?("5.2.2")
      refute MailLog.recipient_failure?("4.0.0")
    end

    test "5.0.x counts only with reply text confirming a dead recipient" do
      refute MailLog.recipient_failure?("5.0.0")
      refute MailLog.recipient_failure?("5.0.0", "552-Quota exceeded")
      refute MailLog.recipient_failure?("5.0.0", "550 permanent failure (x@y:blocked)")

      assert MailLog.recipient_failure?(
               "5.0.0",
               "550 Requested action not taken: mailbox unavailable"
             )

      assert MailLog.recipient_failure?("5.0.0", "550 User unknown")
    end
  end
end
