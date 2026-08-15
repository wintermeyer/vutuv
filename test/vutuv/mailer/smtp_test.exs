defmodule Vutuv.Mailer.SMTPTest do
  @moduledoc """
  Issue #1472: the bounce address must reach the SMTP conversation as the
  RFC 5321 envelope sender (`MAIL FROM`) and must **not** appear as an RFC 5322
  `Sender:` header in the message.

  Both halves are only observable on the wire, so these tests deliver through a
  real (throwaway) SMTP server and read the transcript back. `Vutuv.SMTPSink`
  is that server.
  """
  use ExUnit.Case, async: true

  alias Vutuv.Mailer.SMTP
  alias Vutuv.Notifications.Emailer
  alias Vutuv.SMTPSink

  defp deliver_through(adapter) do
    {:ok, _sink, port} = SMTPSink.start_link(self())

    email =
      Emailer.base_email()
      |> Swoosh.Email.to({"Nobody", "nobody@example.com"})
      |> Swoosh.Email.subject("On the wire")
      |> Swoosh.Email.text_body("hi")

    config = [
      relay: "127.0.0.1",
      port: port,
      tls: :never,
      auth: :never,
      no_mx_lookups: true,
      retries: 0
    ]

    assert {:ok, _receipt} = adapter.deliver(email, config)
    assert_receive {:smtp_session, session}, 5_000

    session
  end

  # The message headers, i.e. everything before the blank line that starts the
  # body. A header assertion must not be satisfied (or defeated) by body text.
  defp headers(session) do
    session.body |> String.split("\r\n\r\n", parts: 2) |> List.first()
  end

  describe "vutuv's adapter" do
    test "announces the bounce address as MAIL FROM" do
      session = deliver_through(SMTP)

      assert session.mail_from == "<bounces@vutuv.de>"
      assert session.rcpt_to == ["<nobody@example.com>"]
    end

    test "puts no Sender header in the message" do
      session = deliver_through(SMTP)

      refute headers(session) =~ ~r/^Sender:/mi
    end

    test "leaves the visible From alone" do
      session = deliver_through(SMTP)

      assert headers(session) =~ ~r/^From: .*no-reply@vutuv\.de/mi
    end
  end

  describe "the upstream adapter this one replaces" do
    # Calibration, not coverage: these two assertions state exactly what
    # `Swoosh.Adapters.SMTP` does differently, so the tests above cannot pass
    # for the wrong reason. `Swoosh.Adapters.SMTP.Helpers.sender/1` is
    # `headers["Sender"] || from`, so upstream can only move the envelope
    # sender by making it a visible header. If this ever goes red because
    # Swoosh grew real envelope-sender support, `Vutuv.Mailer.SMTP` can go.

    test "can only set MAIL FROM through a visible Sender header" do
      {:ok, _sink, port} = SMTPSink.start_link(self())

      email =
        Emailer.base_email()
        |> Swoosh.Email.header("Sender", "bounces@vutuv.de")
        |> Swoosh.Email.to({"Nobody", "nobody@example.com"})
        |> Swoosh.Email.subject("Upstream")
        |> Swoosh.Email.text_body("hi")

      assert {:ok, _receipt} =
               Swoosh.Adapters.SMTP.deliver(email,
                 relay: "127.0.0.1",
                 port: port,
                 tls: :never,
                 auth: :never,
                 no_mx_lookups: true,
                 retries: 0
               )

      assert_receive {:smtp_session, session}, 5_000

      assert session.mail_from == "<bounces@vutuv.de>"
      assert headers(session) =~ ~r/^Sender: bounces@vutuv\.de/mi
    end
  end

  describe "envelope_sender/1" do
    test "falls back to the From for a message built outside the chokepoint" do
      email =
        Swoosh.Email.new()
        |> Swoosh.Email.from({"vutuv", "no-reply@vutuv.de"})

      assert SMTP.envelope_sender(email) == "no-reply@vutuv.de"
    end

    test "prefers the envelope sender the chokepoint stamped" do
      assert SMTP.envelope_sender(Emailer.base_email()) == "bounces@vutuv.de"
    end
  end
end
