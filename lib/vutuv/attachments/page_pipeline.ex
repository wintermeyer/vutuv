defmodule Vutuv.Attachments.PagePipeline do
  @moduledoc """
  The scheduler behind a file's preview pages (issue #2105): renders at most
  `concurrency` files at once, looks for work every few seconds or when an
  upload nudges it, and after a deploy or a crash picks up every file whose
  render died with its process.

  Copied from `Vutuv.Videos.Pipeline`, and for the same reason: the due list is
  a query (`Vutuv.Attachments.Pages.claim_due/1`), never state in this process,
  and a claim is a compare-and-set on the row's heartbeat, so the two slots of
  a blue/green deploy can overlap without rendering the same file twice.

  One at a time by default. A page render is `pdftoppm` plus three AVIF
  encodes, or a headless Chromium — cheaper than a transcode and dearer than a
  thumbnail — and a burst of uploads should queue rather than take the site
  down.

  Off in tests (`:attachment_pipeline`), which drive `Pages.sweep/1` and
  `Pages.render/1` directly.
  """

  use GenServer

  require Logger

  alias Vutuv.Attachments
  alias Vutuv.Attachments.Pages

  @poll_ms :timer.seconds(5)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "A file landed: look for work now rather than at the next poll."
  def nudge do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :nudge)
    :ok
  end

  @impl true
  def init(_opts) do
    send(self(), :poll)
    {:ok, %{running: %{}}}
  end

  @impl true
  def handle_cast(:nudge, state), do: {:noreply, fill(state)}

  @impl true
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, fill(state)}
  end

  # A render finished (everything it decided is on the row, so its result is
  # irrelevant) or died. Either way the slot is free, and the next poll
  # re-claims the file if it still has pages left — a stale heartbeat is how a
  # crash is found.
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, fill(drop(state, ref))}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if reason != :normal,
      do:
        Logger.warning(
          "attachment page render crashed attachment=#{state.running[ref]} " <>
            "reason=#{inspect(reason)}"
        )

    {:noreply, fill(drop(state, ref))}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp drop(state, ref), do: %{state | running: Map.delete(state.running, ref)}

  defp fill(state) do
    free = concurrency() - map_size(state.running)

    if free > 0 and Attachments.enabled?() do
      free
      |> Pages.claim_due()
      |> Enum.reduce(state, fn attachment, acc ->
        task = Task.Supervisor.async_nolink(Vutuv.TaskSupervisor, Pages, :render, [attachment])
        %{acc | running: Map.put(acc.running, task.ref, attachment.id)}
      end)
    else
      state
    end
  end

  defp concurrency do
    :vutuv
    |> Application.fetch_env!(:attachments)
    |> Keyword.get(:render_concurrency, 1)
    |> max(1)
  end
end
