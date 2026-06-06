defmodule Vutuv.Posts.PendingImageSweeper do
  @moduledoc """
  Periodically removes pending post images (uploaded in a composer that was
  never submitted) older than a day — rows and files. Without this, abandoned
  composer sessions slowly fill the disk.

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

  @impl true
  def handle_info(:sweep, state) do
    case Vutuv.Posts.sweep_pending_images() do
      0 -> :ok
      count -> Logger.info("Swept #{count} abandoned pending post image(s)")
    end

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
