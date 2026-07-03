defmodule Vutuv.Newsletters.BroadcastResumer do
  @moduledoc """
  Restarts newsletter broadcasts whose send task died mid-loop.

  A broadcast runs as a plain in-memory task, so a crash (one malformed legacy
  address once killed a whole 2,424-recipient send) or a blue/green deploy
  (the old slot is stopped while the loop runs) leaves the newsletter stuck in
  `sending` with no way to finish from the UI. This sweeper checks once a
  minute for newsletters with no delivery activity for five minutes
  (`Vutuv.Newsletters.stuck_newsletters/1`) and resumes them. A resume never
  double-sends: `resume_broadcast/1` CAS-locks on `updated_at` and the send
  skips recipients who already have a delivery row - including across the two
  slots of a deploy overlap, where the staleness window keeps the new slot's
  hands off a send the old slot is still working through.

  Config-gated off in tests (`:resume_stuck_broadcasts`), like every periodic
  job; tests call `sweep/0` directly.
  """

  use GenServer

  alias Vutuv.Newsletters

  @sweep_ms :timer.minutes(1)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

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

  def handle_info(_other, state), do: {:noreply, state}

  @doc "One pass: resume every stuck broadcast."
  def sweep do
    Enum.each(Newsletters.stuck_newsletters(), &Newsletters.resume_broadcast/1)
  end

  defp schedule, do: Process.send_after(self(), :sweep, @sweep_ms)
end
