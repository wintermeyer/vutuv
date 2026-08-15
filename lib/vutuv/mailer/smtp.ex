defmodule Vutuv.Mailer.SMTP do
  @moduledoc """
  The SMTP adapter vutuv delivers through: `Swoosh.Adapters.SMTP` with the
  RFC 5321 **envelope sender** passed to the SMTP conversation directly,
  instead of smuggled in as a visible RFC 5322 `Sender:` header.

  Upstream has no seam for this. `Swoosh.Adapters.SMTP.Helpers.sender/1` is
  `email.headers["Sender"] || from`, so the only way to move `MAIL FROM` off
  the `From` address is to publish that address as a header — which is how the
  bounce address ended up visible in every vutuv message. Outlook then renders
  `sw@vutuv.de on behalf of vutuv <no-reply@vutuv.de>`, i.e. a mail-handling
  address presented to the reader as the transmitting party (issue #1472).

  So this adapter owns the one call upstream makes and takes the envelope
  sender from `email.private[:envelope_sender]`, which
  `Vutuv.Notifications.Emailer.deliver/1` stamps on every outbound message.
  Everything else — message rendering, DKIM signing, the gen_smtp config
  transformations — is upstream's, unchanged.

  Only production uses it (`config/runtime.exs`); dev previews mail locally and
  the test env uses the Swoosh test adapter, so `Vutuv.Mailer.SMTPTest` drives
  this module against a real throwaway SMTP server rather than through the
  mailer.
  """

  use Swoosh.Adapter, required_config: [:relay], required_deps: [gen_smtp: :gen_smtp_client]

  alias Swoosh.Adapters.SMTP, as: Upstream
  alias Swoosh.Adapters.SMTP.Helpers

  @impl Swoosh.Adapter
  def deliver(%Swoosh.Email{} = email, config) do
    envelope = {envelope_sender(email), recipients(email), Helpers.body(email, config)}

    case :gen_smtp_client.send_blocking(envelope, Upstream.gen_smtp_config(config)) do
      receipt when is_binary(receipt) -> {:ok, receipt}
      {:error, type, message} -> {:error, {type, message}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The address this message announces as `MAIL FROM`, i.e. where delivery
  failures are returned to.

  The chokepoint's stamp when there is one; otherwise upstream's answer, so a
  message assembled outside `Vutuv.Notifications.Emailer` still goes out with a
  sane envelope rather than none.
  """
  def envelope_sender(%Swoosh.Email{} = email) do
    email.private[:envelope_sender] || Helpers.sender(email)
  end

  # Identical to upstream's private all_recipients/1: every address the message
  # is delivered to, deduplicated. Bcc belongs here (the envelope is how a bcc
  # recipient gets the mail at all) even though it is not rendered as a header.
  defp recipients(email) do
    [email.to, email.cc, email.bcc]
    |> Enum.concat()
    |> Enum.map(fn {_name, address} -> address end)
    |> Enum.uniq()
  end
end
