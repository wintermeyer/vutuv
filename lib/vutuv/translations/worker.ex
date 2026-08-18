defmodule Vutuv.Translations.Worker do
  @moduledoc """
  Drains the on-demand translation queue (`Vutuv.Translations.deliver_due/1`)
  — the `Vutuv.Moderation.ImageScanWorker` shape: a slow poll catches retries
  and anything a crash left behind, `nudge/0` serves a reader's fresh request
  without waiting for it. On boot it re-queues jobs stuck mid-translation
  (`resume_stuck/0`), so a restart or deploy never strands a job `running` —
  durable across restarts and power loss by construction, because the row is
  the job.

  The poll carries two more sweeps behind the queue, in this order, and the
  order is the policy: **a reader first, always.** Both of the others are work
  nobody is waiting for.

    * **Background pre-translation** (`Translations.enqueue_background/1`):
      opens jobs for our own posts so the common case is a cache hit and
      nobody waits for a model at all. This is where the yield to image
      moderation lives — while any image scan is open, the worker neither
      opens new background jobs nor drains the ones it already has, because
      both queues share one Ollama and use different models, and a member
      staring at a placecard costs more than a translation arriving a poll
      later. Reader-requested jobs keep draining throughout.
    * **Language detection** (`Translations.detect_due/1`, issue #1535), for
      the posts that declare no language — which is also what feeds the sweep
      above, since a post nobody could place is never a candidate. Its gate
      asks whether a **reader** is waiting, not whether the queue is empty: a
      queue that now has a standing background backlog would otherwise switch
      detection off for good, and the sweep would slowly run out of work it
      could ever do.

  The pile from before the language column existed is meant to be drained by
  `mix vutuv.translations.detect_languages` (or
  `Vutuv.Release.detect_post_languages/1`) in one go rather than by this poll.

  Gated by the `:translation_worker` config flag (off in tests, which call
  `Translations.deliver_due/1` directly with a stubbed translator); the
  actual Ollama call is additionally gated by `:translate_posts`.
  """

  use GenServer

  require Logger

  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Translations
  alias Vutuv.Translations.TranslationJob

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
    precompute()
    detect()
    schedule()
    {:noreply, state}
  end

  # A DB or Ollama hiccup must not take the worker down: the next request (or
  # the next poll) simply tries again.
  defp drain do
    Translations.deliver_due(max_priority: drain_priority())
  rescue
    error -> Logger.error("translation drain failed: #{inspect(error)}")
  end

  # Only on the poll, never on `nudge/0` — a nudge is a reader, and this opens
  # work for nobody in particular.
  defp precompute do
    if drain_priority() == TranslationJob.background_priority() do
      Translations.enqueue_background()
    end
  rescue
    error -> Logger.error("translation precompute failed: #{inspect(error)}")
  end

  # Only on the poll, and only while no READER is waiting: a detection holds
  # this single process for as long as Ollama takes, so anything somebody
  # asked for goes first. Asking about reader work rather than about an empty
  # queue is what keeps the background backlog from switching detection off
  # permanently. That is a check at the top of the round, not a guarantee — a
  # tap landing mid-detection still waits for it, which is the price of one
  # process and a shared box.
  defp detect do
    if not Translations.reader_waiting?(), do: Translations.detect_due()
  rescue
    error -> Logger.error("language detection failed: #{inspect(error)}")
  end

  @doc """
  The worst-ranked job this poll will drain: while a picture is waiting for
  its verdict, only a reader's own request gets the box.

  Fail-open on purpose — if the lookup itself blows up the queue keeps
  draining, because a translation running at an awkward moment is a far
  smaller problem than a queue that stops.
  """
  def drain_priority do
    if image_moderation_busy?() do
      TranslationJob.reader_priority()
    else
      TranslationJob.background_priority()
    end
  end

  defp image_moderation_busy? do
    ImageScans.busy?()
  rescue
    error ->
      Logger.error("image scan check failed: #{inspect(error)}")
      false
  end

  defp schedule do
    if interval = Application.get_env(:vutuv, :translation_poll_interval, @default_interval) do
      Process.send_after(self(), :poll, interval)
    end
  end
end
