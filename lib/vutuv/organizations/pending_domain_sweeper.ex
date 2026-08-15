defmodule Vutuv.Organizations.PendingDomainSweeper do
  @moduledoc """
  Finishes a domain claim nobody is watching (`Vutuv.Organizations.check_pending_domains/0`,
  issue #1466).

  Publishing a DNS record is not an act that completes when the member presses
  Save at their provider: it completes when the record has reached the zone's
  name servers, minutes or hours later and entirely out of their hands. Before
  this sweeper the only thing that ever looked again was the member pressing
  "Verify now", so the reasonable thing to do — publish the record, close the
  tab, get on with the day — was the one thing that never worked.

  Ticks every two minutes, which is the shortest step of the backoff ladder in
  `Vutuv.Organizations`; the ladder, not this interval, decides how often any
  one domain is actually looked at. On success the owners get a mail and any
  open page is told over PubSub.

  Gated twice, like its `Vutuv.Organizations.DomainRecheckSweeper` sibling: the
  child starts only when `:recheck_organization_domains` is on (off in tests, so
  it never touches the SQL sandbox from outside), and the pass itself is a no-op
  when `:verify_organization_domains` is off (intranet installs that must not
  call out).
  """

  use GenServer

  require Logger

  alias Vutuv.Organizations

  @interval :timer.minutes(2)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    try do
      case Organizations.check_pending_domains() do
        0 -> :ok
        count -> Logger.info("Organization domain claims finished in the background: #{count}")
      end
    rescue
      error -> Logger.error("Pending organization domain check failed: #{inspect(error)}")
    end

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
