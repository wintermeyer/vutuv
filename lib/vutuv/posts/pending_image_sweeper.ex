defmodule Vutuv.Posts.PendingImageSweeper do
  @moduledoc """
  Periodically removes pending images (uploaded in a composer that was never
  submitted) older than a day — rows and files, for **both** post and
  job-posting galleries (`Vutuv.Posts.sweep_pending_images/1` +
  `Vutuv.Jobs.sweep_pending_images/1`, the same eager-upload pattern).
  Without this, abandoned composer sessions slowly fill the disk.

  Disabled in tests (`config :vutuv, :sweep_pending_images, false`): the
  sweep would use the SQL Sandbox connection from a process that does not
  own it. The first sweep runs one interval after boot, not at boot, so it
  never races app startup.
  """

  use GenServer

  require Logger

  @interval :timer.hours(6)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule()
    {:ok, nil}
  end

  # Every eager-upload table with the same day-old rule. The clips (issue
  # #1906) are the heaviest: an abandoned one is up to 500 MB of original
  # plus its renditions.
  @sweeps [
    {"post image", &Vutuv.Posts.sweep_pending_images/0},
    {"job-posting image", &Vutuv.Jobs.sweep_pending_images/0},
    {"post video", &Vutuv.Videos.sweep_pending_videos/0}
  ]

  @impl true
  def handle_info(:sweep, state) do
    for {what, sweep} <- @sweeps, count = sweep.(), count > 0 do
      Logger.info("Swept #{count} abandoned pending #{what}(s)")
    end

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
