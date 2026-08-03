defmodule Vutuv.References.SkillRefresher do
  @moduledoc """
  Re-fetches the Arbeitszeugnis analysis prompt once a day
  (`Vutuv.References.Skill.refresh/0`).

  Daily rather than on demand because the prompt is a legal document that
  changes when case law does, not when a member clicks something: a member
  waiting for their check should never also be waiting for GitHub.

  The first run is deferred by `@boot_delay` so a deploy does not spend its
  first seconds on an outbound request, and so a restart loop cannot turn into
  a burst of them. A failed fetch is not an error here — the previously stored
  body, or the vendored copy, stays in force and checks keep running.

  Gated by `:reference_skill_refresher` (off in tests, which call
  `Skill.refresh/0` directly against a stubbed responder).
  """

  use GenServer

  require Logger

  alias Vutuv.References.Skill

  @interval :timer.hours(24)
  @boot_delay :timer.minutes(2)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Refresh now, out of band (a cast to an unstarted refresher is a no-op)."
  def nudge, do: GenServer.cast(__MODULE__, :refresh)

  @impl GenServer
  def init(_opts) do
    schedule(@boot_delay)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_cast(:refresh, state) do
    refresh()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:refresh, state) do
    refresh()
    schedule(interval())
    {:noreply, state}
  end

  # `Skill.refresh/0` already swallows a bad fetch; this rescue is for the
  # unexpected (a database blip), which must not take the timer down with it.
  defp refresh do
    case Skill.refresh() do
      {:ok, version} ->
        Logger.info(
          "reference skill in force: version=#{version.version} " <>
            "source=#{version.source} sha=#{String.slice(version.sha256, 0, 12)}"
        )

      {:error, reason} ->
        Logger.error("reference skill unavailable: #{inspect(reason)}")
    end
  rescue
    error -> Logger.error("reference skill refresh crashed: #{inspect(error)}")
  end

  defp schedule(delay), do: Process.send_after(self(), :refresh, delay)

  defp interval, do: Application.get_env(:vutuv, :reference_skill_interval, @interval)
end
