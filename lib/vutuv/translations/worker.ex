defmodule Vutuv.Translations.Worker do
  @moduledoc """
  Drains the on-demand translation queue (`Vutuv.Translations.deliver_due/1`)
  — the `Vutuv.Moderation.ImageScanWorker` shape: a slow poll catches retries
  and anything a crash left behind, `nudge/0` serves a reader's fresh request
  without waiting for it. On boot it re-queues jobs stuck mid-translation
  (`resume_stuck/0`), so a restart or deploy never strands a job `running` —
  durable across restarts and power loss by construction, because the row is
  the job.

  A job exists only because a reader asked for that translation, so an empty
  queue is the normal, correct state — there is no repair sweep over
  translations here.

  The poll does carry one sweep, after the queue: language detection
  (`Translations.detect_due/1`, issue #1535), for the posts that declare no
  language. It runs **behind** the reader-driven queue in every round and in a
  small batch, because a reader waits for a translation and nobody waits for a
  detection. The pile from before the language column existed is meant to be
  drained by `mix vutuv.translations.detect_languages` (or
  `Vutuv.Release.detect_post_languages/1`) in one go rather than by this poll.

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
    detect()
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

  # Only on the poll, never on `nudge/0`, and only while the queue is empty: a
  # detection is nobody waiting, but it holds this single process for as long as
  # Ollama takes, so anything a reader asked for goes first. That is a check at
  # the top of the round, not a guarantee — a tap landing mid-detection still
  # waits for it, which is the price of one process and a shared box.
  defp detect do
    if Translations.list_due(limit: 1) == [], do: Translations.detect_due()
  rescue
    error -> Logger.error("language detection failed: #{inspect(error)}")
  end

  defp schedule do
    if interval = Application.get_env(:vutuv, :translation_poll_interval, @default_interval) do
      Process.send_after(self(), :poll, interval)
    end
  end
end
