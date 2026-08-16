defmodule Vutuv.Translations.Worker do
  @moduledoc """
  Drains the on-demand translation queue (`Vutuv.Translations.deliver_due/1`)
  — the `Vutuv.Moderation.ImageScanWorker` shape: a slow poll catches retries
  and anything a crash left behind, `nudge/0` serves a reader's fresh request
  without waiting for it. On boot it re-queues jobs stuck mid-translation
  (`resume_stuck/0`), so a restart or deploy never strands a job `running` —
  durable across restarts and power loss by construction, because the row is
  the job.

  There is no backfill and no repair sweep here on purpose: a job exists only
  because a reader asked for that translation, so an empty queue is the
  normal, correct state.

  Gated by the `:translation_worker` config flag (off in tests, which call
  `Translations.deliver_due/1` directly with a stubbed translator); the
  actual Ollama call is additionally gated by `:translate_posts`.
  """

  use GenServer

  require Logger

  alias Vutuv.Translations

  # Slow on purpose: `nudge/0` covers the interactive path, the poll only
  # catches backed-off retries and crash leftovers.
  @default_interval :timer.seconds(30)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Translate now (a cast to an unstarted worker is a harmless no-op)."
  def nudge, do: GenServer.cast(__MODULE__, :drain)

  @impl GenServer
  def init(_opts) do
    Translations.resume_stuck()
    schedule()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_cast(:drain, state) do
    drain()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    drain()
    schedule()
    {:noreply, state}
  end

  # A DB or Ollama hiccup must not take the worker down: the next request (or
  # the next poll) simply tries again.
  defp drain do
    Translations.deliver_due()
  rescue
    error -> Logger.error("translation drain failed: #{inspect(error)}")
  end

  defp schedule do
    if interval = Application.get_env(:vutuv, :translation_poll_interval, @default_interval) do
      Process.send_after(self(), :poll, interval)
    end
  end
end
