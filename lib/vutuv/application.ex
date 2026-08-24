defmodule Vutuv.Application do
  @moduledoc false

  use Application

  require Logger

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

  @doc """
  The modules whose log level this app raises at boot, this one included.

  It carries its own override so the boot line below survives a global level
  quieter than `:info`, which is what production runs by default.
  """
  def ops_log_modules, do: [__MODULE__ | @ops_log_modules]

  @doc """
  Applies the per-module log-level override and says so in the log.

  The line matters as much as the override (issue #1575). A per-module level
  is invisible to every check an operator reaches for — `Logger.level/0`,
  `Application.get_env(:logger, :level)` and `:logger.get_primary_config/0`
  all keep answering `:error` — and `bin/vutuv eval` never runs `start/2`, so
  a fresh VM cannot see it either. Asking the running node is not a given
  either: a release started with `RELEASE_DISTRIBUTION=none` (what vutuv.de
  runs) has no node to attach to, so `bin/vutuv rpc` answers *"Cannot run
  --rpc-eval if the node is not alive"* and `remote` the same. That left the
  journal contradicting `config/prod.exs` with nothing anywhere to explain
  it. So the node states its own deviation once per boot, in the journal that
  shows the symptom:

      journalctl -u <the vutuv unit> | grep logger_override
  """
  def ensure_ops_logs_visible do
    :ok = Logger.put_module_level(ops_log_modules(), :info)

    Logger.info(fn ->
      "logger_override primary=#{Logger.level()} raised_to=info modules=" <>
        Enum.map_join(ops_log_modules(), ",", &inspect/1)
    end)
  end

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
        # Owns the live people counter in the top bar (members here plus the
        # distinct Fediverse accounts following them). Starts after the Repo (it
        # seeds from it) and PubSub (it broadcasts over it).
        Vutuv.PeopleCounter,
        # Snapshots the "most followed members" pool for the profile's
        # who-to-follow card and the public listing. Starts after the Repo (it
        # seeds the snapshot from it).
        Vutuv.Social.PopularUsers,
        # Snapshots the "who to follow" recent-poster pool the profile rail
        # draws from — same deal as PopularUsers. Starts after the Repo.
        Vutuv.Posts.TopPosters,
        # Snapshots the candidate pool the feed's "Vorschläge" rail draws from,
        # per locale — same deal again. Starts after the Repo.
        Vutuv.Posts.PopularPosts,
        # Fans a :day_changed broadcast out at Berlin midnight so open pages
        # re-render "today"/"Gestern" post timestamps. Needs PubSub only.
        Vutuv.DayClock,
        # Must start after PubSub (it depends on it) and before the Endpoint.
        VutuvWeb.Presence,
        {Task.Supervisor, name: Vutuv.TaskSupervisor},
        # The loopback SOCKS5 proxy every screenshot-Chromium egresses through
        # (per-connection SSRF vetting; see its moduledoc for why it replaced
        # the `MAP *` DNS pin). Starts after the TaskSupervisor (connection
        # handlers run under it). Unconditional even where captures are off
        # (tests, air-gapped installs): one idle loopback listener, and the
        # capture path fails closed on `port/1` when it is missing.
        Vutuv.Ssrf.SocksProxy,
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
        # The single-use dead-render -> socket-mount handoff for the profile
        # and the feed (owns its ETS table + expiry sweeper). Before the
        # Endpoint so the table exists for the first request.
        VutuvWeb.Live.MountHandoff,
        VutuvWeb.Endpoint
      ] ++
        optional_child(:prefs_defaults_cache, Vutuv.Prefs.Cache) ++
        optional_child(:screenshot_blocklist_cache, Vutuv.ScreenshotBlocklist.Cache) ++
        optional_child(:sweep_pending_images, Vutuv.Posts.PendingImageSweeper) ++
        optional_child(:sweep_post_drafts, Vutuv.Posts.DraftSweeper) ++
        optional_child(
          :sweep_unconfirmed_registrations,
          Vutuv.Accounts.UnconfirmedRegistrationSweeper
        ) ++
        optional_child(:sweep_account_events, Vutuv.AccountEvents.Sweeper) ++
        optional_child(:sweep_api_auth, Vutuv.ApiAuth.Sweeper) ++
        optional_child(:send_unread_message_emails, Vutuv.Chat.UnreadNotifier) ++
        optional_child(:send_notification_digest_emails, Vutuv.Activity.DigestNotifier) ++
        optional_child(:moderation_sweeper, Vutuv.Moderation.Sweeper) ++
        optional_child(:webhook_deliverer, Vutuv.Webhooks.Deliverer) ++
        optional_child(:fediverse_deliverer, Vutuv.Fediverse.Deliverer) ++
        optional_child(:fediverse_follower_pruning, Vutuv.Fediverse.FollowerPruner) ++
        optional_child(:fediverse_note_sweeping, Vutuv.Fediverse.NoteSweeper) ++
        optional_child(:fediverse_counts, Vutuv.Fediverse.CountsRefresher) ++
        optional_child(:post_screenshot_worker, Vutuv.Posts.ScreenshotWorker) ++
        optional_child(:image_scan_worker, Vutuv.Moderation.ImageScanWorker) ++
        optional_child(:translation_worker, Vutuv.Translations.Worker) ++
        optional_child(:reference_check_worker, Vutuv.References.CheckWorker) ++
        optional_child(:reference_skill_refresher, Vutuv.References.SkillRefresher) ++
        optional_child(:daily_report_email, Vutuv.Reports.DailyReporter) ++
        optional_child(:record_people_history, Vutuv.PeopleHistory.Recorder) ++
        optional_child(:bounce_watcher, Vutuv.Deliverability.Watcher) ++
        optional_child(:sweep_unreachable_accounts, Vutuv.Deliverability.Sweeper) ++
        optional_child(:resume_stuck_broadcasts, Vutuv.Newsletters.BroadcastResumer) ++
        optional_child(:recheck_organization_domains, Vutuv.Organizations.DomainRecheckSweeper) ++
        optional_child(
          :recheck_organization_domains,
          Vutuv.Organizations.PendingDomainSweeper
        ) ++
        optional_child(:recheck_user_links, Vutuv.Profiles.LinkRecheckSweeper) ++
        optional_child(
          :recheck_social_accounts,
          Vutuv.Profiles.SocialAccountRecheckSweeper
        ) ++
        optional_child(:jobs_sweeper, Vutuv.Jobs.Sweeper) ++
        optional_child(:saved_search_alerts, Vutuv.SavedSearches.AlertSweeper) ++
        optional_child(:auto_post_deletion_sweeper, Vutuv.Posts.AutoDeletionSweeper)

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
