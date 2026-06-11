defmodule Vutuv.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Vutuv.Repo,
        {Phoenix.PubSub, name: Vutuv.PubSub},
        # Owns the live member counter behind the landing page. Starts after the
        # Repo (it seeds from it) and PubSub (it broadcasts over it).
        Vutuv.Accounts.MemberCounter,
        # Must start after PubSub (it depends on it) and before the Endpoint.
        VutuvWeb.Presence,
        {Task.Supervisor, name: Vutuv.TaskSupervisor},
        Vutuv.RateLimiter,
        VutuvWeb.Endpoint
      ] ++
        optional_child(:sweep_pending_images, Vutuv.Posts.PendingImageSweeper) ++
        optional_child(
          :sweep_unconfirmed_registrations,
          Vutuv.Accounts.UnconfirmedRegistrationSweeper
        ) ++
        optional_child(:send_unread_message_emails, Vutuv.Chat.UnreadNotifier) ++
        optional_child(:moderation_sweeper, Vutuv.Moderation.Sweeper) ++
        optional_child(:webhook_deliverer, Vutuv.Webhooks.Deliverer)

    opts = [strategy: :one_for_one, name: Vutuv.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The periodic jobs, each behind a config flag so tests can turn them off:
  # their DB work would use the SQL Sandbox connection from a process that
  # does not own it (same reasoning as :generate_screenshots). Tests call the
  # underlying functions directly instead.
  defp optional_child(env_key, module) do
    if Application.get_env(:vutuv, env_key, true), do: [module], else: []
  end

  @impl true
  def config_change(changed, _new, removed) do
    VutuvWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
