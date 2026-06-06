defmodule Vutuv.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Vutuv.Repo,
        {Phoenix.PubSub, name: Vutuv.PubSub},
        # Must start after PubSub (it depends on it) and before the Endpoint.
        VutuvWeb.Presence,
        {Task.Supervisor, name: Vutuv.TaskSupervisor},
        Vutuv.RateLimiter,
        VutuvWeb.Endpoint
      ] ++ sweeper()

    opts = [strategy: :one_for_one, name: Vutuv.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Off in tests: the sweep would use the SQL Sandbox connection from a
  # process that does not own it (same reasoning as :generate_screenshots).
  defp sweeper do
    if Application.get_env(:vutuv, :sweep_pending_images, true) do
      [Vutuv.Posts.PendingImageSweeper]
    else
      []
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    VutuvWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
