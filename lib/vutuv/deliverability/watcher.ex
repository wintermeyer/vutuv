defmodule Vutuv.Deliverability.Watcher do
  @moduledoc """
  Tails the Postfix delivery log and turns vutuv hard bounces into action.

  The production host is a multi-tenant relay whose `vutuv.de` MX is on Google,
  so a bounce DSN never reaches a local pipe; the log is the signal instead
  (see `docs/production-email-and-bounces.md`). This process polls the log
  file, hands new lines to `Vutuv.Deliverability.MailLog` for attribution and
  classification, and feeds confirmed hard bounces to
  `Vutuv.Deliverability.record_hard_bounce/3`. Policy bounces (`5.7.x` - our own
  SPF/DKIM/DMARC, or the remote's policy) are logged as an ops warning, never
  acted on.

  It starts at end-of-file, so a restart never re-processes the historical log
  (which would re-action month-old bounces). Rotation is handled by noticing the
  file shrank and re-reading from the top. Enabled only where a log path is
  configured (`config :vutuv, #{inspect(__MODULE__)}, path: ..., poll_ms: ...`);
  with no path it does not start, so dev and test never touch the filesystem.
  """

  use GenServer

  require Logger

  alias Vutuv.Deliverability
  alias Vutuv.Deliverability.MailLog

  @default_poll_ms 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    config = Application.get_env(:vutuv, __MODULE__, [])
    path = if config[:path] in [nil, ""], do: nil, else: config[:path]
    poll_ms = config[:poll_ms] || @default_poll_ms

    if path do
      {offset, inode} = stat(path)
      Logger.info("Deliverability.Watcher tailing #{path} from offset #{offset}")
      schedule(poll_ms)

      {:ok, %{path: path, offset: offset, inode: inode, poll_ms: poll_ms, parser: MailLog.new()}}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:poll, state) do
    state =
      case File.stat(state.path) do
        {:ok, %{size: size, inode: inode}} -> read_new(state, size, inode)
        {:error, _reason} -> state
      end

    schedule(state.poll_ms)
    {:noreply, state}
  end

  # Read whatever is new since last time. A changed inode (logrotate
  # rename+create) or a file smaller than our offset (copytruncate) means it
  # rotated; start again from the top of the new file.
  defp read_new(%{offset: prev, inode: prev_inode} = state, size, inode) do
    offset = if inode != prev_inode or size < prev, do: 0, else: prev
    state = %{state | inode: inode}

    if size <= offset do
      %{state | offset: offset}
    else
      case read_window(state.path, offset, size - offset) do
        {:ok, data} ->
          {lines, consumed} = complete_lines(data)
          parser = process(lines, state.parser)
          %{state | offset: offset + consumed, parser: parser}

        :error ->
          %{state | offset: offset}
      end
    end
  end

  # Only the part up to the last newline is complete; hold back any trailing
  # partial line until the next poll has the rest.
  defp complete_lines(data) do
    case :binary.matches(data, "\n") do
      [] ->
        {[], 0}

      matches ->
        {start, _len} = List.last(matches)
        consumed = start + 1
        complete = binary_part(data, 0, consumed)
        {String.split(complete, "\n", trim: true), consumed}
    end
  end

  defp process(lines, parser) do
    {events, parser} = MailLog.reduce(lines, parser)
    Enum.each(events, &act/1)
    parser
  end

  defp act(%{ours?: false}), do: :ok

  defp act(%{class: :hard_bounce, to: to, dsn: dsn, line: line}) do
    Deliverability.record_hard_bounce(to, dsn, line)
  end

  defp act(%{class: :policy, to: to, dsn: dsn}) do
    Logger.warning(
      "Deliverability: policy bounce to #{to} (#{dsn}) - our outbound mail may be failing authentication (SPF/DKIM/DMARC). Not deactivating."
    )
  end

  defp act(_event), do: :ok

  # The close lives in an `after`, not on the success path. `File.open/2`
  # without `:raw` spawns an IO-server process linked to this GenServer, and the
  # old shape closed it only when both the seek and the read succeeded — so the
  # `else` branch dropped the handle still open. That branch is reachable:
  # `IO.binread/2` answers `:eof` when the log is truncated between the
  # `File.stat` in `handle_info(:poll, …)` and this read, which is exactly what
  # logrotate's `copytruncate` does. This process polls every five seconds for
  # the life of the release, so each such race leaked one fd on the mail host
  # permanently.
  defp read_window(path, offset, length) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          with {:ok, _pos} <- :file.position(io, offset),
               data when is_binary(data) <- IO.binread(io, length) do
            {:ok, data}
          else
            _other -> :error
          end
        after
          File.close(io)
        end

      {:error, _reason} ->
        :error
    end
  end

  defp stat(path) do
    case File.stat(path) do
      {:ok, %{size: size, inode: inode}} -> {size, inode}
      {:error, _reason} -> {0, nil}
    end
  end

  defp schedule(poll_ms), do: Process.send_after(self(), :poll, poll_ms)
end
