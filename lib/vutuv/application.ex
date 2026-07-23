defmodule Vutuv.Application do
  @moduledoc false

  use Application

  # Some subsystems carry deliberate ops alarms that production's quiet global
  # Logger level (:error, config/prod.exs) would swallow entirely.
  #
  # The email-deliverability ones: the watcher's policy-bounce warning (it
  # fires when *our* SPF/DKIM sending is broken for a whole class of
  # recipients), its startup line (the only liveness signal), the DSN
  # webhook's bounce lines, the sweeper's counts and the emailer's
  # dropped-mail warnings. Nobody could have seen any of them until v7.122.5.
  #
  # And the AI image scan: every `image_scan` line is about a member's image
  # being deleted (or nearly deleted) by a machine, which is exactly what an
  # operator has to be able to read back when someone appeals or when the
  # prompt needs calibrating — at :error the whole feed would be silent.
  #
  # Raise exactly these modules to :info at boot; everything else stays at
  # the global level. Off in tests (config/test.exs), which want the quiet
  # :warning default.
  @ops_log_modules [
    Vutuv.Deliverability.Watcher,
    Vutuv.Deliverability.Sweeper,
    Vutuv.Moderation.ImageScans,
    Vutuv.Notifications.Bounces,
    Vutuv.Notifications.Emailer
  ]

  @doc "Per-module log-level override making the deliverability ops alarms visible."
  def ensure_ops_logs_visible, do: Logger.put_module_level(@ops_log_modules, :info)

  @impl true
  def start(_type, _args) do
    if Application.get_env(:vutuv, :ops_log_visibility, true), do: ensure_ops_logs_visible()
    # The optional children below are gated per config flag (off in tests, see
    # config/test.exs): mostly periodic jobs, plus the Vutuv.Prefs.Cache,
    # whose DB reloads would likewise touch the SQL sandbox from outside.
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
        optional_child(:prefs_defaults_cache, Vutuv.Prefs.Cache) ++
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
        optional_child(:post_screenshot_worker, Vutuv.Posts.ScreenshotWorker) ++
        optional_child(:image_scan_worker, Vutuv.Moderation.ImageScanWorker) ++
        optional_child(:daily_report_email, Vutuv.Reports.DailyReporter) ++
        optional_child(:bounce_watcher, Vutuv.Deliverability.Watcher) ++
        optional_child(:sweep_unreachable_accounts, Vutuv.Deliverability.Sweeper) ++
        optional_child(:resume_stuck_broadcasts, Vutuv.Newsletters.BroadcastResumer) ++
        optional_child(:recheck_organization_domains, Vutuv.Organizations.DomainRecheckSweeper) ++
        optional_child(:recheck_user_links, Vutuv.Profiles.LinkRecheckSweeper) ++
        optional_child(:jobs_sweeper, Vutuv.Jobs.Sweeper) ++
        optional_child(:saved_search_alerts, Vutuv.SavedSearches.AlertSweeper)

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
