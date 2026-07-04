defmodule Vutuv.Notifications.Bounces do
  @moduledoc """
  Inbound bounce handling (RFC 3464 delivery status notifications).

  Every vutuv email leaves with its SMTP envelope sender set to the bounce
  address (the `Sender` header; see `Emailer.deliver/1`), so remote mail
  systems return DSNs to exactly one mailbox. Production Postfix pipes that
  mailbox into `POST /webhooks/bounces` (see `scripts/postfix/`), which
  lands here.

  A failure DSN (`Action: failed`) records an `EmailBounce`, but only a
  **recipient-failure** status code (`5.0.x` / `5.1.x` / `5.5.x`: no such
  user, mailbox unavailable, bad address — `Vutuv.Deliverability.MailLog.recipient_failure?/1`)
  marks the address undeliverable (`emails.undeliverable_at`). A policy
  failure (`5.7.x`, e.g. a DMARC/authentication rejection, often the sender's
  own transient config problem) or a transient one (`4.x`) is logged and left
  alone, so the webhook agrees with the production log watcher's single
  classification rather than deactivating a live address on every DSN.
  `Emailer.deliver/1` drops *automatic* mail to a suppressed address. User-
  initiated PIN mail keeps sending — one full mailbox must never lock its
  owner out for good — and a successful login PIN through the address proves
  delivery works again, so `Vutuv.Accounts.check_pin/3` clears the mark.

  Delay DSNs (`Action: delayed`) are ignored: the MTA is still retrying.
  """

  import Ecto.Query

  require Logger

  alias Vutuv.Accounts.Email
  alias Vutuv.Deliverability
  alias Vutuv.Deliverability.MailLog
  alias Vutuv.Repo

  @doc """
  Records one raw DSN message. Returns `{:ok, :failed}` when a recipient
  failure was recorded (address deactivated), `{:ok, :ignored}` for a
  non-recipient failure (policy/transient) or a non-failure DSN (delays,
  relays), `{:error, :unparseable}` when no recipient/action could be
  extracted.
  """
  def record(raw) when is_binary(raw) do
    case parse(raw) do
      {recipients, "failed", status} when is_binary(status) ->
        if MailLog.recipient_failure?(status) do
          record_hard_bounces(recipients, status, raw)
          {:ok, :failed}
        else
          # A policy (5.7.x) or transient (4.x) failure must NOT deactivate a
          # live address — mirrors MailLog so the webhook and the log watcher
          # never disagree.
          Logger.info(
            "Email bounce: ignoring non-recipient failure (#{status}) for " <>
              Enum.join(recipients, ", ")
          )

          {:ok, :ignored}
        end

      {recipients, "failed", nil} ->
        # A failure DSN with no parseable Status: can't classify it as a
        # recipient failure, so conservatively don't deactivate.
        Logger.info(
          "Email bounce: ignoring failure with no status for #{Enum.join(recipients, ", ")}"
        )

        {:ok, :ignored}

      {recipients, action, _status} ->
        Logger.info("Email bounce: ignoring '#{action}' DSN for #{Enum.join(recipients, ", ")}")
        {:ok, :ignored}

      :error ->
        {:error, :unparseable}
    end
  end

  # A recipient-failure code means the mailbox is dead. Same path as the
  # production log watcher: each address goes through Vutuv.Deliverability,
  # which appends to the bounce ledger, marks the address undeliverable, and
  # re-assesses the owner (possibly freezing an unreachable account).
  defp record_hard_bounces(recipients, status, raw) do
    for address <- recipients do
      Deliverability.record_hard_bounce(address, status, raw)
      Logger.warning("Email bounce: #{address} failed (#{status})")
    end
  end

  @doc "Whether automatic mail to this address is currently suppressed."
  def suppressed?(address) when is_binary(address) do
    address = String.downcase(address)

    Repo.exists?(from(e in Email, where: e.value == ^address and not is_nil(e.undeliverable_at)))
  end

  def suppressed?(_address), do: false

  @doc "Clears the undeliverable mark - delivery to the address provably works."
  def clear(address) when is_binary(address) do
    address = String.downcase(address)

    {count, _} =
      from(e in Email, where: e.value == ^address and not is_nil(e.undeliverable_at))
      |> Repo.update_all(set: [undeliverable_at: nil])

    if count > 0, do: Logger.info("Email bounce: cleared undeliverable mark for #{address}")
    :ok
  end

  # Pulls the per-recipient report fields out of the message/delivery-status
  # part. Plain regex over the raw text: DSN field syntax is line-based, and
  # vutuv mail has a single recipient, so one Action/Status pair per message
  # is the reality this needs to handle.
  defp parse(raw) do
    recipients =
      ~r/^(?:Final|Original)-Recipient:\s*rfc822;\s*<?([^>\s;]+@[^>\s;]+?)>?\s*$/im
      |> Regex.scan(raw, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()

    action =
      case Regex.run(~r/^Action:\s*(\w+)/im, raw, capture: :all_but_first) do
        [action] -> String.downcase(action)
        nil -> nil
      end

    status =
      case Regex.run(~r/^Status:\s*(\d\.\d{1,3}\.\d{1,3})/im, raw, capture: :all_but_first) do
        [status] -> status
        nil -> nil
      end

    if recipients != [] and action, do: {recipients, action, status}, else: :error
  end
end
