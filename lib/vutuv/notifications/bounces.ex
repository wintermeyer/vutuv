defmodule Vutuv.Notifications.Bounces do
  @moduledoc """
  Inbound bounce handling (RFC 3464 delivery status notifications).

  Every vutuv email leaves with its SMTP envelope sender set to the bounce
  address (the `Sender` header; see `Emailer.deliver/1`), so remote mail
  systems return DSNs to exactly one mailbox. Production Postfix pipes that
  mailbox into `POST /webhooks/bounces` (see `scripts/postfix/`), which
  lands here.

  A failure DSN (`Action: failed` — including the final DSN Postfix sends
  when it gives up retrying a soft failure) records an `EmailBounce` and
  marks the address undeliverable (`emails.undeliverable_at`).
  `Emailer.deliver/1` then drops *automatic* mail to it. User-initiated PIN
  mail keeps sending — one full mailbox must never lock its owner out for
  good — and a successful login PIN through the address proves delivery
  works again, so `Vutuv.Accounts.check_pin/3` clears the mark.

  Delay DSNs (`Action: delayed`) are ignored: the MTA is still retrying.
  """

  import Ecto.Query

  require Logger

  alias Vutuv.Accounts.Email
  alias Vutuv.Deliverability
  alias Vutuv.Repo

  @doc """
  Records one raw DSN message. Returns `{:ok, :failed}` when a failure was
  recorded, `{:ok, :ignored}` for non-failure DSNs (delays, relays),
  `{:error, :unparseable}` when no recipient/action could be extracted.
  """
  def record(raw) when is_binary(raw) do
    case parse(raw) do
      {recipients, "failed", status} ->
        # The DSN webhook and the production log watcher share one path: each
        # confirmed failure goes through Vutuv.Deliverability, which appends to
        # the bounce ledger, marks the address undeliverable, and re-assesses
        # the owner (possibly freezing an unreachable account).
        for address <- recipients do
          Deliverability.record_hard_bounce(address, status, raw)
          Logger.warning("Email bounce: #{address} failed (#{status})")
        end

        {:ok, :failed}

      {recipients, action, _status} ->
        Logger.info("Email bounce: ignoring '#{action}' DSN for #{Enum.join(recipients, ", ")}")
        {:ok, :ignored}

      :error ->
        {:error, :unparseable}
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
