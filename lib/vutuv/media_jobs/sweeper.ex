defmodule Vutuv.MediaJobs.Sweeper do
  @moduledoc """
  Deletes media-job rows past their retention window (see the Retention
  section of `Vutuv.MediaJobs`).

  It prunes by age rather than picking work oldest-first, so the sweeper-clock
  trap does not apply — a row it deletes cannot come round again. Runs daily,
  first sweep one interval after boot so it never races startup, and rescues
  its own errors like every other sweeper beside the media pipelines: a
  database hiccup must not take it down. Disabled in tests
  (`config :vutuv, :sweep_media_jobs, false`), where the sweep would use the
  SQL Sandbox connection from a process that does not own it — tests call
  `Vutuv.MediaJobs.delete_expired/0` directly.
  """

  use GenServer

  require Logger

  @interval :timer.hours(24)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule()
    {:noreply, state}
  end

  defp sweep do
    case Vutuv.MediaJobs.delete_expired() do
      0 -> :ok
      count -> Logger.info("Deleted #{count} expired media job(s)")
    end
  rescue
    error -> Logger.error("media job sweep failed: #{inspect(error)}")
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
