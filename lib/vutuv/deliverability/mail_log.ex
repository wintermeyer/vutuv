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
      (`5.1.x` / `5.5.x`: no such user, mailbox unavailable, invalid address),
      or generic `5.0.x` whose reply text itself confirms a dead recipient.
      The address is dead; deactivate it.
    * `:policy` - `status=bounced` with `5.7.x` (authentication / DMARC), or
      `5.0.x` whose text names a recipient-side block. A sender- or
      policy-side problem, **not** the recipient. Never deactivate; it can
      mean our own sending is broken for a whole class of recipients.
    * `:transient` - `status=deferred`, or any `4.x.x`. Postfix keeps retrying.
    * `:delivered` - `status=sent`.
    * `:other` - any other `5.x.x` bounce (e.g. `5.2.x` full/disabled mailbox,
      `5.4.x` routing), a `5.0.x` quota reply, or a `5.0.x` with unrecognized
      text. Left alone, conservatively, to avoid false positives.

  `5.0.x` needs the text vetting because it is not an enhanced code from the
  remote server: Postfix maps any bare `550`/`552` reply to it, so the bucket
  mixes dead mailboxes with full mailboxes (`552 Quota exceeded`) and
  recipient-side spam/IP blocks. Treating the whole bucket as dead recipients
  froze 19 live accounts after the July 2026 newsletters.
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

  # Reply-text evidence for the generic `5.0.x` bucket (all shapes seen in the
  # production log). Contra-indications are checked first: they name a working
  # mailbox that refused this one message (or a problem with *our* sending),
  # so they must win over a dead-recipient phrase in the same multi-cause
  # reply ("Recipient address rejected: Access denied").
  @full_mailbox_text ~r/quota|storage allocation|mailbox (?:is )?full|insufficient storage/i
  @blocked_text ~r/blocked|blacklist|denylist|spam|banned|denied|reputation|sender (?:address )?(?:rejected|verify failed)/i
  @dead_recipient_text ~r/user unknown|unknown (?:user|recipient|address)|address unknown|mailbox \S+ unknown|no such (?:user|recipient|mailbox|address)|does not exist|not found|no mailbox|mailbox unavailable|invalid (?:recipient|mailbox)|no longer (?:available|on system)|address rejected|unroutable|unrouteable/i

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
              class: classify(status, dsn, line),
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

  @doc """
  Classifies a delivery result. `text` is the raw reply/log text, consulted
  only for the generic `5.0.x` bucket (see the moduledoc); without it a
  `5.0.x` bounce conservatively classifies as `:other`.
  """
  @spec classify(String.t(), String.t(), String.t()) :: atom()
  def classify(status, dsn, text \\ "")
  def classify("sent", _dsn, _text), do: :delivered
  def classify("deferred", _dsn, _text), do: :transient
  def classify("bounced", dsn, text), do: bounce_class(dsn, text)
  def classify(_status, _dsn, _text), do: :other

  @doc """
  Whether a bounce is a confirmed dead recipient (vs a policy, mailbox-state
  or transient problem). The enhanced-code families `5.1.x` (addressing / no
  such user) and `5.5.x` (mailbox unavailable) count on their own; the generic
  `5.0.x` bucket counts only when `text` (the raw reply) itself confirms a
  dead recipient - it also carries full-mailbox and recipient-side-block
  replies, which are not.
  """
  @spec recipient_failure?(String.t(), String.t()) :: boolean()
  def recipient_failure?(dsn, text \\ "") do
    cond do
      Regex.match?(~r/^5\.(1|5)\./, dsn) -> true
      String.starts_with?(dsn, "5.0.") -> generic_bounce_class(text) == :hard_bounce
      true -> false
    end
  end

  defp bounce_class(dsn, text) do
    cond do
      String.starts_with?(dsn, "4.") -> :transient
      String.starts_with?(dsn, "5.0.") -> generic_bounce_class(text)
      recipient_failure?(dsn) -> :hard_bounce
      String.starts_with?(dsn, "5.7.") -> :policy
      true -> :other
    end
  end

  # A `5.0.x` code carries no evidence of its own, so the reply text decides:
  # contra-indications first (full mailbox -> :other, recipient-side block ->
  # :policy), then a confirming dead-recipient phrase (-> :hard_bounce),
  # otherwise leave it alone.
  defp generic_bounce_class(text) do
    text = reply_text(text)

    cond do
      Regex.match?(@full_mailbox_text, text) -> :other
      Regex.match?(@blocked_text, text) -> :policy
      Regex.match?(@dead_recipient_text, text) -> :hard_bounce
      true -> :other
    end
  end

  # The evidence is the remote server's own words. A full log line also
  # carries relay hostnames (a real trap: relay=mx10.mailspamprotection.com
  # made a dead-recipient reply match the "spam" contra-indication), so cut
  # down to the reply: the part after `said: `, else after `status=xxx (`
  # (replies with no `said:`, e.g. local errors), else the text as given
  # (webhook Diagnostic-Code lines).
  defp reply_text(text) do
    case Regex.run(~r/said: (.*)/s, text, capture: :all_but_first) do
      [reply] ->
        reply

      nil ->
        case Regex.run(~r/status=\w+ \((.*)/s, text, capture: :all_but_first) do
          [reply] -> reply
          nil -> text
        end
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
