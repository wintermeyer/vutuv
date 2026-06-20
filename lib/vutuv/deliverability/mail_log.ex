defmodule Vutuv.Deliverability.MailLog do
  @moduledoc """
  Pure parser for Postfix delivery-result lines in `/var/log/mail.log`.

  Production bounce detection reads the mail log rather than a bounce mailbox
  (the host is a multi-tenant relay and `vutuv.de`'s MX is on Google, so a DSN
  to `bounces@vutuv.de` would never reach a local pipe; see
  `docs/production-email-and-bounces.md`). This module turns raw log lines into
  attributed, classified delivery results; `Vutuv.Deliverability.Watcher` is the
  stateful process that feeds it lines and acts on the results.

  ## Attribution

  A delivery line carries the recipient (`to=<...>`) but **not** the envelope
  sender, and the relay sends for several apps. So a `status=bounced` line is
  only ours when its queue-id was previously seen on a `from=<bounces@vutuv.de>`
  line. `reduce/2` folds over lines in order, remembering each queue-id's
  envelope sender in a bounded window, and marks each delivery `ours?`
  accordingly.

  ## Classification (see the DSN-code table in the ops doc)

    * `:hard_bounce` - `status=bounced` with a recipient-failure code
      (`5.0.x` / `5.1.x` / `5.5.x`: no such user, mailbox unavailable, invalid
      address). The address is dead; deactivate it.
    * `:policy` - `status=bounced` with `5.7.x` (authentication / DMARC). A
      sender- or policy-side problem, **not** the recipient. Never deactivate;
      it means our own sending is broken for a whole class of recipients.
    * `:transient` - `status=deferred`, or any `4.x.x`. Postfix keeps retrying.
    * `:delivered` - `status=sent`.
    * `:other` - any other `5.x.x` bounce (e.g. `5.2.x` full/disabled mailbox,
      `5.4.x` routing). Left alone, conservatively, to avoid false positives.
  """

  @max_tracked 2000

  defstruct senders: %{}, order: []

  @type t :: %__MODULE__{senders: map(), order: [String.t()]}

  @type delivery :: %{
          queue_id: String.t(),
          to: String.t(),
          dsn: String.t(),
          status: String.t(),
          class: atom(),
          ours?: boolean(),
          line: String.t()
        }

  # `postfix/qmgr[2473331]: B080C3A8049A: from=<bounces@vutuv.de>, size=...`
  @envelope_re ~r/postfix\/[a-z]+\[\d+\]: ([0-9A-Za-z]{6,}): from=<([^>]*)>/
  # `postfix/smtp[948]: 70EE...: to=<x@y>, relay=..., dsn=5.1.2, status=bounced (...)`
  @delivery_re ~r/postfix\/[a-z]+\[\d+\]: ([0-9A-Za-z]{6,}): to=<([^>]*)>.*?dsn=([0-9.]+), status=(\w+)/

  @doc "A fresh, empty fold state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Folds `lines` (a list of raw log lines, oldest first) through `state`,
  returning `{deliveries, new_state}`. `deliveries` are the delivery-result
  lines seen this batch, each attributed (`ours?`) and classified (`class`).
  Carry `new_state` into the next call so attribution survives across batches.
  """
  @spec reduce([String.t()], t()) :: {[delivery()], t()}
  def reduce(lines, %__MODULE__{} = state) do
    {events, state} =
      Enum.reduce(lines, {[], state}, fn line, {events, state} ->
        case parse_line(line) do
          {:envelope, queue_id, from} ->
            {events, track(state, queue_id, from)}

          {:delivery, queue_id, to, dsn, status} ->
            event = %{
              queue_id: queue_id,
              to: String.downcase(to),
              dsn: dsn,
              status: status,
              class: classify(status, dsn),
              ours?: Map.get(state.senders, queue_id) == our_sender(),
              line: line
            }

            {[event | events], state}

          :ignore ->
            {events, state}
        end
      end)

    {Enum.reverse(events), state}
  end

  @doc "Parses one line into `{:envelope, qid, from}`, `{:delivery, qid, to, dsn, status}`, or `:ignore`."
  @spec parse_line(String.t()) ::
          {:envelope, String.t(), String.t()}
          | {:delivery, String.t(), String.t(), String.t(), String.t()}
          | :ignore
  def parse_line(line) do
    cond do
      caps = Regex.run(@delivery_re, line) ->
        [_, queue_id, to, dsn, status] = caps
        {:delivery, queue_id, to, dsn, status}

      caps = Regex.run(@envelope_re, line) ->
        [_, queue_id, from] = caps
        {:envelope, queue_id, String.downcase(from)}

      true ->
        :ignore
    end
  end

  @doc "Classifies a delivery result. See the moduledoc."
  @spec classify(String.t(), String.t()) :: atom()
  def classify("sent", _dsn), do: :delivered
  def classify("deferred", _dsn), do: :transient
  def classify("bounced", dsn), do: bounce_class(dsn)
  def classify(_status, _dsn), do: :other

  @doc """
  Whether a DSN code names a dead recipient (vs a policy or transient problem).
  Recipient-failure families only: `5.0.x` (generic permanent), `5.1.x`
  (addressing / no such user), `5.5.x` (mailbox unavailable).
  """
  @spec recipient_failure?(String.t()) :: boolean()
  def recipient_failure?(dsn), do: Regex.match?(~r/^5\.(0|1|5)\./, dsn)

  defp bounce_class(dsn) do
    cond do
      String.starts_with?(dsn, "4.") -> :transient
      recipient_failure?(dsn) -> :hard_bounce
      String.starts_with?(dsn, "5.7.") -> :policy
      true -> :other
    end
  end

  defp track(%__MODULE__{senders: senders, order: order} = state, queue_id, from) do
    senders = Map.put(senders, queue_id, from)
    order = [queue_id | order]

    if map_size(senders) > @max_tracked do
      {keep, drop} = Enum.split(order, @max_tracked)
      %{state | senders: Map.drop(senders, drop), order: keep}
    else
      %{state | senders: senders, order: order}
    end
  end

  defp our_sender, do: Application.get_env(:vutuv, :bounce_address, "bounces@vutuv.de")
end
