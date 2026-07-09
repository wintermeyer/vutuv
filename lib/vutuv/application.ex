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
        # Snapshots the "most followed members" pool for the who-to-follow
        # rails and the public listing. Starts after the Repo (it seeds the
        # snapshot from it).
        Vutuv.Social.PopularUsers,
        # Fans a :day_changed broadcast out at Berlin midnight so open pages
        # re-render "today"/"Gestern" post timestamps. Needs PubSub only.
        Vutuv.DayClock,
        # Must start after PubSub (it depends on it) and before the Endpoint.
        VutuvWeb.Presence,
        {Task.Supervisor, name: Vutuv.TaskSupervisor},
        # Caches + single-flights the inline social feed fetches (Mastodon,
        # Bluesky). Starts after the TaskSupervisor (its fetch tasks run under
        # it); does no work until a profile visit asks, and the per-provider
        # feature flags gate that in tests.
        Vutuv.SocialFeed.Cache,
        # Single-flights the background code-forge stats fetches (GitHub,
        # GitLab, Codeberg — Vutuv.CodeStats). Starts after the TaskSupervisor
        # (its fetch tasks run under it); does no work until an account save
        # or a stale profile view asks, and :fetch_code_stats gates that in
        # tests.
        Vutuv.CodeStats.Fetcher,
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
        optional_child(:prune_search_history, Vutuv.Search.HistorySweeper) ++
        optional_child(:webhook_deliverer, Vutuv.Webhooks.Deliverer) ++
        optional_child(:fediverse_deliverer, Vutuv.Fediverse.Deliverer) ++
        optional_child(:daily_report_email, Vutuv.Reports.DailyReporter) ++
        optional_child(:bounce_watcher, Vutuv.Deliverability.Watcher) ++
        optional_child(:sweep_unreachable_accounts, Vutuv.Deliverability.Sweeper) ++
        optional_child(:resume_stuck_broadcasts, Vutuv.Newsletters.BroadcastResumer)

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
