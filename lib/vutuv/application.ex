defmodule Vutuv.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Vutuv.Repo,
      {Phoenix.PubSub, name: Vutuv.PubSub},
      {Task.Supervisor, name: Vutuv.TaskSupervisor},
      Vutuv.RateLimiter,
      VutuvWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Vutuv.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    VutuvWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
