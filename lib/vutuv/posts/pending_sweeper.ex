defmodule Vutuv.Posts.PendingSweeper do
  @moduledoc """
  The backstop behind a waiting post (issue #2106).

  A post is normally published the moment its last medium settles, by the
  pipeline that settled it (`Vutuv.Posts.Pending.media_changed/2`). That nudge
  is a message in a process, and a blue/green deploy stops the slot holding it
  mid-flight with nothing logged anywhere — so the member's text would sit
  there for ever with every file ready.

  This is what finds it again, once a minute: the due list is a **query**
  (`Pending.due/1`), so this process holds no state a restart can lose, and a
  publish is claimed by a compare-and-set, so the two slots of a deploy overlap
  cannot publish the same text. It also picks up a claim a dead slot left
  standing — recognising by the id the claim minted whether the post is already
  there, rather than writing it twice.

  Off in tests (`:pending_sweeper`), which drive `Pending.sweep/1` directly.
  """

  use GenServer

  require Logger

  alias Vutuv.Posts.Pending

  @interval :timer.minutes(1)
  @batch 20

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    schedule()
    drain()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # A failure here must never take the sweeper down: the next pass finds the
  # same rows, and a crash loop would take the whole backstop with it.
  defp drain do
    Pending.sweep(@batch)
  rescue
    error -> Logger.error("pending post sweep failed: #{inspect(error)}")
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
