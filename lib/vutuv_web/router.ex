defmodule VutuvWeb.Router do
  use VutuvWeb, :router
  alias VutuvWeb.Plug, as: Plugs

  if Mix.env() == :dev do
    forward("/sent_emails", Plug.Swoosh.MailboxPreview)
  end

  pipeline :browser do
    # activity+json rides along so ActivityPub requests reach the profile and
    # post-permalink controllers (they branch on FediverseController.ap_request?
    # and fall back to plain HTML for everyone else).
    plug(:accepts, ["html", "activity+json"])
    plug(:fetch_session)
    plug(:fetch_flash)
    # Records a click on a newsletter's tracked vutuv.de link and redirects to
    # the clean URL. Early, so a tracked click never does the rest of the
    # pipeline's per-request work just to throw the page away on the redirect.
    plug(Plugs.NewsletterClick)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(Plugs.ContentSecurityPolicy)
    # Link headers advertising llms.txt/sitemap and the page's agent-format
    # alternates (HTML-free discovery).
    plug(Plugs.AgentLinks)
    plug(:put_root_layout, html: {VutuvWeb.LayoutHTML, :root})
    plug(Plugs.ConfigureSession, repo: Vutuv.Repo)
    plug(Plugs.Locale)
    # The daily text ad between navigation and content (1/hour per session).
    plug(Plugs.AdBanner)
  end

  pipeline :user_pipe do
    # Keep the per-user detail pages (phone numbers, emails, addresses, …) out
    # of search indexes. Runs first so the header is present even when a later
    # plug halts (e.g. an unknown slug 404s). The profile page itself (/:slug)
    # does not go through this pipeline and stays crawlable.
    plug(Plugs.NoIndex)
    plug(Plugs.UserResolveSlug)
    plug(Plugs.EnsureActivated)
    plug(Plugs.AgentExportOptOut)
  end

  # The user-agnostic settings scope: every /settings/* page operates on the
  # logged-in member (SettingsUser assigns :user = :current_user), so one
  # shareable URL — vutuv.de/settings/links — opens each member's own editor,
  # while the /:slug twins stay the public showcase view. NoIndex keeps the
  # editor pages out of search results.
  pipeline :settings_pipe do
    plug(Plugs.NoIndex)
    plug(Plugs.RequireLogin)
    plug(Plugs.SettingsUser)
    plug(Plugs.EnsureActivated)
  end

  # Gates the whole /admin scope in one place, so a new admin controller
  # cannot forget the auth plugs and ship world-accessible.
  pipeline :admin do
    plug(Plugs.RequireLogin)
    plug(Plugs.AuthAdmin)
  end

  # Like :browser, but deliberately WITHOUT CSRF protection and without the
  # ad banner: the RFC 8058 one-click unsubscribe POST comes from the mail
  # provider with no cookies and no token. The signed token in the URL is the
  # authorization, and the action only ever switches notification mail off.
  pipeline :unsubscribe do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_flash)
    plug(:put_secure_browser_headers)
    plug(Plugs.ContentSecurityPolicy)
    plug(:put_root_layout, html: {VutuvWeb.LayoutHTML, :root})
    plug(Plugs.ConfigureSession, repo: Vutuv.Repo)
    plug(Plugs.Locale)
  end

  # The versioned third-party JSON API (see Vutuv.ApiAuth and /developers).
  # Bearer tokens only — no session, no CSRF; CORS is wide open because no
  # cookie ever authenticates here. ApiCors must run before ApiV2Auth so
  # preflights (sent without an Authorization header) are answered.
  pipeline :api_v2 do
    plug(:accepts, ["json"])
    plug(Plugs.ApiCors)
    plug(Plugs.ApiV2Auth)
  end

  # The OAuth machine endpoints: form-encoded in (parsed at the endpoint),
  # JSON out, no session, no CSRF — RFC 6749's token/revocation endpoints.
  pipeline :oauth_token do
    plug(:accepts, ["json"])
  end

  # Served from the app (not priv/static, which is gitignored) and with no
  # pipeline so crawlers that send "Accept: text/plain" are not turned away
  # by the browser pipeline's `accepts ["html"]`.
  scope "/", VutuvWeb do
    get("/robots.txt", PageController, :robots)
    # The agent-format discovery file (llms.txt convention): documents the
    # .md/.txt/.json/.vcf URL scheme; see VutuvWeb.AgentDocs.
    get("/llms.txt", PageController, :llms)
    # Sitemap index + chunked children (see Vutuv.Sitemap for the queries).
    get("/sitemap.xml", SitemapController, :index)
    get("/sitemaps/:name", SitemapController, :show)
    # RSS 2.0 post feeds (VutuvWeb.Feeds): site-wide and per member. Both
    # must beat the catch-all /:slug routes further down, and feed readers
    # send Accept: application/rss+xml, which the browser pipeline rejects.
    get("/posts/feed.xml", FeedController, :site)
    get("/:slug/posts/feed.xml", FeedController, :user)
    # Link-preview images (VutuvWeb.OpenGraph): the brand card and the
    # member avatar as a scraper-friendly JPEG. The consumers are the
    # WhatsApp/Facebook/... scrapers, not browsers.
    get("/og-card.png", PageController, :og_card)
    get("/:slug/avatar.jpg", AvatarController, :show)
    # Agent-skills discovery (Cloudflare draft) + security.txt (RFC 9116).
    get("/.well-known/agent-skills/index.json", WellKnownController, :agent_skills_index)
    get("/.well-known/agent-skills/vutuv/SKILL.md", WellKnownController, :agent_skill)
    get("/.well-known/security.txt", WellKnownController, :security_txt)
    get("/security.txt", WellKnownController, :security_txt)
    # ActivityPub follow-only federation (Vutuv.Fediverse): WebFinger
    # discovery plus the per-member actor endpoints. Machine-to-machine like
    # the feeds above — no session/CSRF; the inbox authenticates remote
    # servers by HTTP signature instead. All of it 404s for members without
    # the opt-in and while :fediverse_enabled is off.
    get("/.well-known/webfinger", FediverseController, :webfinger)
    get("/:slug/actor", FediverseController, :actor)
    get("/:slug/actor/followers", FediverseController, :followers)
    get("/:slug/actor/outbox", FediverseController, :outbox)
    post("/:slug/actor/inbox", FediverseController, :inbox)
    # Deploy readiness probe (see VutuvWeb.HealthController). No pipeline:
    # it is hit by curl on localhost and must not depend on sessions or
    # content negotiation.
    get("/health", HealthController, :index)
    # Bounce ingestion: production Postfix pipes the bounce mailbox into this
    # (scripts/postfix/vutuv-bounce). Bearer-token auth in the controller; no
    # pipeline so the raw message/rfc822 body stays unparsed and no CSRF or
    # session machinery gets in the way of a machine-to-machine POST.
    post("/webhooks/bounces", WebhookController, :bounces)
  end

  scope "/", VutuvWeb do
    pipe_through(:browser)

    resources("/tags", TagController, only: [:index, :show], param: "slug")

    get("/", PageController, :index)
    get("/impressum", PageController, :impressum)
    get("/datenschutzerklaerung", PageController, :datenschutzerklaerung)
    get("/nutzungsbedingungen", PageController, :nutzungsbedingungen)
    # People paste the literal placeholder "username" from instructions ("your
    # profile lives at vutuv.de/username") into the address bar. A dedicated
    # route before the /:slug catch-all answers it with a helper page that
    # explains the placeholder and points at a real example, instead of a bare
    # 404. "benutzername" is the German placeholder the username help text shows
    # (vutuv.de/benutzername). Both are ReservedSlugs so no member can shadow them.
    get("/username", PageController, :username_placeholder)
    get("/benutzername", PageController, :username_placeholder)
    # The July 2026 newsletter shipped its profile link with the {{username}}
    # merge tag unsubstituted inside the href (the Markdown autolinker had
    # percent-encoded the braces, hiding the tag from the substitution), so
    # thousands of inboxes link to /%7B%7Busername%7D%7D. Phoenix matches
    # routes on percent-DECODED segments, so this literal route catches those
    # clicks: logged-in members go to their own profile (what the link meant),
    # everyone else gets the placeholder helper. Braces are invalid in
    # usernames, so no member can ever shadow it.
    get("/{{username}}", PageController, :newsletter_username_placeholder)
    get("/listings/most_followed_users", PageController, :most_followed_users)

    # The public member directory: the A-Z overview plus one page per letter.
    # The crawl surface for search engines that follow links instead of
    # reading /sitemap.xml, and a browsable index for humans (the letter
    # pages carry agent-format siblings). It lives under /system/ — the one
    # reserved word future site pages share, so each new page stops burning
    # another root path word that members could have had as a handle.
    get("/system/members", DirectoryController, :index)
    get("/system/members/:letter", DirectoryController, :show)

    # Username-independent profile permalink (issue #904): keyed on the member's
    # never-changing UUID v7 id, it 302-redirects to their current /:username, so
    # a link built from it survives every rename. Under /system/ so it does not
    # burn a root path word; multi-segment, so no collision with the /:slug
    # profile catch-all further down.
    get("/system/permalinks/users/:user_id", PermalinkController, :user)

    # Invite a friend: the form and its submission. Logged-in only (the
    # controller's RequireLogin plug). It lives under /system/ like the member
    # directory, so it does not permanently burn a root path word a member
    # could claim as a handle. POST records + emails the invitation.
    get("/system/invitations/new", InvitationController, :new)
    post("/system/invitations", InvitationController, :create)

    # The signed-in member's newsfeed. A controller (not a bare `live`) so it
    # can negotiate the agent-format siblings (/feed.md/.txt/.json/.xml,
    # VutuvWeb.AgentDocs) and live_render the LiveView for HTML. A literal route
    # before the /:slug catch-all ("feed" is a ReservedSlug). Named
    # NewsfeedController so it doesn't collide with FeedController (the RSS one).
    get("/feed", NewsfeedController, :index)

    # Verified organization pages (issue #929). Controllers (not bare `live`) so
    # /organizations and /organizations/:slug negotiate their agent-format siblings
    # (.md/.txt/.json/.xml, VutuvWeb.AgentDocs) and live_render the LiveView for
    # HTML — the profile/newsfeed pattern. Literal routes before the /:slug
    # catch-all ("organizations" is a ReservedSlug); /organizations/new (claim wizard)
    # precedes /organizations/:slug, /organizations/:slug/edit is the owner edit form.
    get("/organizations", OrganizationController, :index)
    get("/organizations/new", OrganizationController, :new)
    get("/organizations/:slug", OrganizationController, :show)
    get("/organizations/:slug/edit", OrganizationController, :edit)
    # The owner-only team roster and multi-domain management pages (issue #930),
    # live_render like edit. The fixed second segment keeps them out of the
    # /:slug agent-format catch-all.
    get("/organizations/:slug/roles", OrganizationController, :roles)
    get("/organizations/:slug/domains", OrganizationController, :domains)

    get("/new_registration", PageController, :redirect_index)
    post("/new_registration", PageController, :new_registration)

    resources("/follows", FollowController, only: [:create, :delete])
    # Mute / unmute a follow you own: toggles `muted`, which drops the followee's
    # posts out of your feed while the follow (and any vernetzt status) stays.
    put("/follows/:id/mute", FollowController, :toggle_mute)

    # Liking / bookmarking a *member* (the private, silent save the profile
    # header offers, the people-equivalent of a post like/bookmark). POST to
    # save, DELETE /:id (the target member's id) to remove. Logged-in only
    # (checked in the controller).
    post("/user_bookmarks", UserSaveController, :bookmark)
    delete("/user_bookmarks/:id", UserSaveController, :unbookmark)
    post("/user_likes", UserSaveController, :like)
    delete("/user_likes/:id", UserSaveController, :unlike)

    # Promote a map service to the viewer's default (the primary "Open in …"
    # button on address cards). Fired by the MapLinks enhancement in app.js when
    # a logged-in member opens a non-default service. Logged-in only. See
    # VutuvWeb.MapPreferenceController.
    post("/maps/default", MapPreferenceController, :update)

    # Vernetzt = a mutual follow, so there is no connection lifecycle any more:
    # you just follow (above), and a follow-back makes you vernetzt. The list
    # lives at /:slug/connections in the profile scope below (read-only).

    # Search is a LiveView (live "/search" in the live_session below): results
    # stream in while typing and ?q= keeps the URL shareable. The pre-LiveView
    # POST endpoint and the stored-query URLs (/search/:id, where the id is the
    # query value itself) bounce into it.
    post("/search", LegacyRedirectController, :search_post)
    get("/search/:id", LegacyRedirectController, :search_show)

    # Login/logout under the names humans type. The controller still speaks
    # "session": POST /login handles both PIN steps, DELETE /logout signs out.
    # /login/resend mails a fresh PIN; /login/cancel abandons a pending login so
    # the visitor is no longer pinned to the PIN-entry form.
    get("/login", SessionController, :new)
    post("/login", SessionController, :create)
    post("/login/resend", SessionController, :resend)
    post("/login/cancel", SessionController, :cancel)
    delete("/logout", SessionController, :delete)

    # Passkey login (issue #795): the two-request WebAuthn ceremony, an
    # alternative first factor to the email PIN. /challenge mints + stores a
    # challenge, /passkey verifies the assertion and logs in. JSON, driven by
    # assets/js/webauthn.js. The email-PIN flow above is the always-available
    # fallback and the only way a passkey is ever enrolled.
    post("/login/passkey/challenge", SessionController, :passkey_challenge)
    post("/login/passkey", SessionController, :passkey_verify)

    # PIN-entry step for the account-deletion flow (issue #759).
    post("/account_deletion", UserController, :confirm_delete)

    # The authorizing post-image proxy: every post-image byte goes through
    # the app so the post's audience guards its images too. `:version` is
    # e.g. "feed.avif"; nginx only streams what this controller approves.
    get("/post_images/:token/:version", PostImageController, :show)

    # The authorizing organization-image proxy (logo/cover + description images),
    # like /post_images: a pending or frozen page's images are owner/admin-only.
    get("/organization_images/:token/:version", OrganizationImageController, :show)

    # The authorizing job-posting-image proxy, like /post_images.
    get("/job_posting_images/:token/:version", JobPostingImageController, :show)

    # Post deletion (the permalink lives in the profile scope below; "posts"
    # is in ReservedSlugs).
    delete("/posts/:id", PostController, :delete)

    # The community guidelines every moderation email and report form links to.
    get("/community", PageController, :community)

    # Developer documentation for /api/2.0 (English; "developers" is in
    # ReservedSlugs). Each page also serves its raw Markdown under .md.
    # The app registry routes must precede the docs' :page catch.
    post("/developers/apps/:id/regenerate_secret", DevAppController, :regenerate_secret)
    get("/developers/apps/:app_id/webhooks/new", DevWebhookController, :new)
    post("/developers/apps/:app_id/webhooks", DevWebhookController, :create)
    post("/developers/apps/:app_id/webhooks/:id/ping", DevWebhookController, :ping)
    post("/developers/apps/:app_id/webhooks/:id/reactivate", DevWebhookController, :reactivate)
    delete("/developers/apps/:app_id/webhooks/:id", DevWebhookController, :delete)
    resources("/developers/apps", DevAppController)
    get("/developers", DevDocController, :index)
    get("/developers/:page", DevDocController, :show)

    # The OAuth consent screen (the machine endpoints /oauth/token and
    # /oauth/revoke live in their own session-free scope below).
    get("/oauth/authorize", OauthController, :authorize)
    post("/oauth/authorize", OauthController, :approve)

    # The member's side of OAuth: which apps may act for them, one-click
    # revoke ("connected_apps" is in ReservedSlugs).
    resources("/connected_apps", ConnectedAppController, only: [:index, :delete])

    # The daily text ad: the public offer page, the booking flow and the
    # member's booking dashboard (logged-in only; checked in the
    # controller). See Vutuv.Ads; admin approval lives under /admin/ads.
    get("/ads", AdController, :index)
    get("/ads/new", AdController, :new)
    # POST /ads/new is the "edit again" leg of the preview step: it re-renders
    # the form with the submitted values; /ads/preview shows the ad as the
    # banner will render it before the binding POST /ads books it.
    post("/ads/new", AdController, :new)
    post("/ads/preview", AdController, :preview)
    get("/ads/bookings", AdController, :bookings)
    post("/ads", AdController, :create)

    # Blocking: the profile-footer Block control, the private blocked list,
    # and unblocking. Logged-in only ("blocks" is in ReservedSlugs).
    resources("/blocks", BlockController, only: [:index, :create, :delete])

    # Personal access tokens for /api/2.0 ("access_tokens" is in
    # ReservedSlugs). Logged-in only. The collection DELETE (no id) is the
    # panic button: revoke every token at once.
    delete("/access_tokens", AccessTokenController, :delete_all)
    resources("/access_tokens", AccessTokenController, only: [:index, :new, :create, :delete])

    # Reporting content (family-friendliness / bullying / spam): the form and
    # its submission. Logged-in only; checked in the controller.
    get("/reports/new", ReportController, :new)
    post("/reports", ReportController, :create)

    # The evidence-render page headless Chromium shoots for a reported
    # message (the thread is private; the short-lived signed token is the
    # capture's key). Not linked anywhere, noindexed, 404 on a bad token.
    get("/moderation/evidence/:token", ModerationEvidenceController, :show)

    # The owner's side of a moderation case: the case page with the
    # delete / edit / "my content is fine" self-service actions.
    get("/moderation/cases", ModerationCaseController, :index)
    get("/moderation/cases/:id", ModerationCaseController, :show)
    post("/moderation/cases/:id/dispute", ModerationCaseController, :dispute)
    post("/moderation/cases/:id/delete_content", ModerationCaseController, :delete_content)
  end

  # The OAuth token machinery (see the :oauth_token pipeline above).
  scope "/oauth", VutuvWeb do
    pipe_through(:oauth_token)

    post("/token", OauthController, :token)
    post("/revoke", OauthController, :revoke)
  end

  # Switching notification emails off without a login (the email footer link
  # and the providers' one-click POST). See the :unsubscribe pipeline above.
  scope "/", VutuvWeb do
    pipe_through(:unsubscribe)

    get("/unsubscribe/:token", UnsubscribeController, :show)
    post("/unsubscribe/:token", UnsubscribeController, :create)
  end

  # Legacy URLs from before profiles moved to the root (and before the
  # /sessions and /search_queries renames). GET-only 301s; see the controller.
  scope "/", VutuvWeb do
    pipe_through(:browser)

    get("/sessions/new", LegacyRedirectController, :login)
    get("/search_queries/new", LegacyRedirectController, :search)
    get("/search_queries/:id", LegacyRedirectController, :search_query)
    get("/users/:slug", LegacyRedirectController, :user)
    get("/users/:slug/*rest", LegacyRedirectController, :user_subpage)
  end

  # Incremental LiveView surface. `InitAssigns` assigns `:current_user` from the
  # session so the shared layout renders the logged-in chrome over the socket.
  live_session :default,
    on_mount: [{VutuvWeb.Live.InitAssigns, :default}],
    root_layout: {VutuvWeb.LayoutHTML, :root} do
    scope "/", VutuvWeb do
      pipe_through(:browser)

      live("/notifications", NotificationLive.Index, :index)
      # Search-as-you-type ("search" is a reserved slug; open to visitors).
      live("/search", SearchLive, :index)
      live("/messages", MessageLive.Index, :index)
      # The profile "Message" button: open my conversation with that member
      # (find-or-create), then land in the thread.
      live("/messages/with/:slug", MessageLive.Index, :new)
      live("/messages/:id", MessageLive.Index, :show)

      # The post editor ("posts" is a ReservedSlug). Auth is checked in the
      # mounts. The newsfeed itself is NOT here: it serves agent-format
      # siblings (/feed.md/.txt/.json/.xml) too, which need a controller in
      # front to negotiate the format, so it lives under FeedController below.
      live("/posts/:id/edit", PostLive.Edit, :edit)
      live("/posts/:id/reply", PostLive.Reply, :new)

      # The private likes / bookmarks lists (reserved slugs too).
      live("/likes", PostLive.Saved, :likes)
      live("/bookmarks", PostLive.Saved, :bookmarks)

      # Job postings ("jobs" is a ReservedSlug). Auth is checked in the mounts.
      # The two-segment owner routes (/jobs/mine, /jobs/new) are defined before
      # the /jobs/:slug detail route so they are never captured as a slug. The
      # public /jobs board (#933) is a controller in front of the embedded
      # `JobBoardLive` so it can negotiate its agent-format siblings
      # (/jobs.md/.txt/.json/.xml), like the detail page below.
      get("/jobs", JobPostingController, :index)
      live("/jobs/mine", JobPostingLive.Dashboard, :index)
      live("/jobs/new", JobPostingLive.Form, :new)
      live("/jobs/:slug/edit", JobPostingLive.Form, :edit)
      get("/jobs/:slug", JobPostingController, :show)
      post("/jobs/:slug/apply", JobPostingController, :apply)
    end

    # The add-tag form previews, as the member types, exactly which tags a
    # submit will attach (issue #848). It saves over the socket too, so the
    # dead UserTagController keeps only manage + delete (and the public
    # index/show/endorsers).
    scope "/settings", VutuvWeb do
      pipe_through([:browser, :settings_pipe])

      live("/tags/new", TagNewLive, :new)

      # The job-search viewer-exclusion list (issue #938): add/remove members
      # and email domains that never see the member's availability or salary
      # expectation. A LiveView so rows add/remove with no reload; it
      # broadcasts on the owner's Activity topic so an open profile updates too.
      live("/job_search_exclusions", JobSearchExclusionsLive, :index)
    end
  end

  scope "/admin", VutuvWeb.Admin, as: :admin do
    pipe_through([:browser, :admin])
    resources("/", AdminController, only: [:index])

    # The daily activity report: confirmed-by-PIN registrations and the day's
    # posts, reposts, likes and bookmarks. ?date time-travels to any past day;
    # Vutuv.Reports.DailyReporter mails the previous day's copy each night.
    get("/reports", ReportController, :index)

    # The moderation queue + case page are LiveViews (in the live_session below)
    # so rulings act reload-free. These classic routes stay: /reporters (the
    # read-only misuse dashboard), the private evidence-screenshot stream, and the
    # uphold/reject POSTs that are the no-JS / scriptable fallback for the rulings.
    # /reporters and /:id/evidence are defined before the live `/moderation/:id`
    # (earlier scope wins) so the literal/suffixed segments still match first.
    get("/moderation/reporters", ModerationController, :reporters)
    get("/moderation/:id/evidence", ModerationController, :evidence)
    post("/moderation/:id/uphold", ModerationController, :uphold)
    post("/moderation/:id/reject", ModerationController, :reject)
    post("/moderation/:id/remove", ModerationController, :remove)

    # The ad review dashboard: every booked ad is approved here before it
    # serves (see Vutuv.Ads.approve_ad/2). :show is the per-ad detail page.
    get("/ads", AdController, :index)
    get("/ads/:id", AdController, :show)
    post("/ads/:id/approve", AdController, :approve)

    # Force-rename a member out of an unwanted username (the old name is not
    # blocked afterwards). GET renders the form; POST does the rename.
    get("/usernames", UsernameController, :index)
    post("/usernames", UsernameController, :update)

    # The installation's preference defaults (Vutuv.Prefs): what every member
    # who has not customized — and every logged-out visitor — gets. The form
    # is generated from the registry; saving reloads every node's cache.
    get("/preferences", PrefController, :index)
    put("/preferences", PrefController, :update)

    # Per-member preference overrides for support: set or clear (back to
    # "inherit the installation default") any registry pref of one member.
    # Defined before the live `/users` routes match nothing here — the extra
    # /preferences segment keeps it distinct from /users/delete and /users.
    get("/users/:id/preferences", UserPrefController, :show)
    put("/users/:id/preferences", UserPrefController, :update)

    # The member browser is a LiveView (`UserLive`, in the live_session below) so
    # search/filter/sort update with no reload. :update is the identity-
    # verification write action the browser's inline Verify button and this
    # legacy POST both use.
    post("/users", UserController, :update)

    # The Honor tags overview: the discoverable home for the admin-granted
    # badges (mint one in a step, see holder counts, jump to each roster).
    # Defined before the tag catalog so `/admin/honor_tags` is a distinct path,
    # not swallowed by `/admin/tags/:slug`.
    get("/honor_tags", HonorTagController, :index)
    post("/honor_tags", HonorTagController, :create)

    resources("/tags", TagController, param: "slug")

    # The member roster of an honor tag (the "vutuv_developer" badge):
    # add a member by @handle/email, remove one. Only meaningful for a tag
    # flagged honor?; the roster block on the tag's show page is gated on
    # it. `:id` on delete is the member's user id.
    post("/tags/:tag_slug/members", TagMemberController, :create)
    delete("/tags/:tag_slug/members/:id", TagMemberController, :delete)

    # The registered OAuth apps + the bad-player kill switch. The list is a
    # LiveView (below) so suspend/unsuspend act reload-free; these POSTs are the
    # no-JS / scriptable fallback.
    post("/api_apps/:id/suspend", ApiAppController, :suspend)
    post("/api_apps/:id/unsuspend", ApiAppController, :unsuspend)

    # Email deliverability: bounced/deactivated addresses, accounts frozen
    # because every address is dead, the bounce ledger and the audit trail. The
    # dashboard itself is a LiveView (`DeliverabilityLive`, in the live_session
    # below) so thaw/clear act reload-free; these two POSTs are the no-JS /
    # scriptable fallback. thaw lifts a freeze; clear lifts an address's mark.
    post("/deliverability/users/:id/thaw", DeliverabilityController, :thaw)
    post("/deliverability/emails/:id/clear", DeliverabilityController, :clear_address)

    # The installation's legal pages (Impressum, Datenschutzerklärung,
    # Nutzungsbedingungen): per-installation trusted Markdown, edited here,
    # rendered by the public PageController routes. The set of pages is fixed,
    # so there is no :new/:create/:delete.
    get("/legal", LegalPageController, :index)
    get("/legal/:slug/edit", LegalPageController, :edit)
    put("/legal/:slug", LegalPageController, :update)

    # The email newsletter ("Rundbrief"): compose/store a draft, send a test to
    # one address, broadcast to all members, and read the per-recipient delivery
    # log. See Vutuv.Newsletters; test/broadcast are the two extra POST actions.
    # /clicks is the link-click detail log behind the success overview.
    resources("/newsletters", NewsletterController)
    post("/newsletters/:id/test", NewsletterController, :test)
    get("/newsletters/:id/clicks", NewsletterController, :clicks)
  end

  # The newsletter audience builder is a LiveView (live "how many match" count as
  # you adjust filters), so it gets its own admin live_session. The dead :admin
  # pipeline 403s the disconnected render; :require_admin guards the socket.
  live_session :admin,
    on_mount: [
      {VutuvWeb.Live.InitAssigns, :default},
      {VutuvWeb.Live.InitAssigns, :require_admin}
    ],
    root_layout: {VutuvWeb.LayoutHTML, :root} do
    scope "/admin", VutuvWeb.Admin, as: :admin do
      pipe_through([:browser, :admin])

      # The member browser: a live, filterable, searchable, sortable list of
      # every account (default: PIN-registered, newest first).
      live("/users", UserLive, :index)

      # Search for an account and delete it behind an "Are you sure?" modal.
      # Deletion removes everything the account owns and emails the operator.
      live("/users/delete", UserDeleteLive, :index)

      # The deliverability dashboard: thaw/clear act reload-free over the socket.
      live("/deliverability", DeliverabilityLive, :index)

      # The moderation queue + case page: rulings (uphold/reject) act reload-free
      # and drop back to the queue. /moderation/reporters + /:id/evidence stay
      # classic (defined earlier above, so they match before this :id route).
      live("/moderation", ModerationLive, :index)
      live("/moderation/:id", ModerationCaseLive, :show)

      # The OAuth-application list: suspend/unsuspend act reload-free.
      live("/api_apps", ApiAppLive, :index)

      # The post link-screenshot subsystem: a Queue tab (pending/capturing/failed
      # jobs) and a Gallery tab (captured screenshots linked to their posts),
      # both paginated. Read-only. ?tab= switches, ?page= paginates.
      live("/screenshots", ScreenshotLive, :index)

      live("/newsletters/:id/send", NewsletterBroadcastLive)

      live("/newsletter_groups", NewsletterGroupLive, :index)
      live("/newsletter_groups/new", NewsletterGroupLive, :new)
      live("/newsletter_groups/:id", NewsletterGroupLive, :show)
      live("/newsletter_groups/:id/edit", NewsletterGroupLive, :edit)

      # The verified-organization oversight dashboard (issue #930): freeze/unfreeze/
      # archive/delete act reload-free over the socket.
      live("/organizations", OrganizationLive, :index)
    end
  end

  # /api/2.0 — the authenticated third-party API. Contract: additions are
  # free, breaking changes mean /api/v2 (a new scope here).
  scope "/api/2.0", VutuvWeb.ApiV2, as: :api_v2 do
    pipe_through(:api_v2)

    # Every route DECLARES the scope it needs in its assigns; the pipeline's
    # ApiV2Auth plug enforces it and refuses to serve a route that forgot to
    # declare one — default-deny, so an endpoint can never ship unchecked.

    get("/me", MeController, :show, assigns: %{api_scope: "profile:read"})
    patch("/me", MeController, :update, assigns: %{api_scope: "profile:write"})

    get("/users/:slug", UserController, :show, assigns: %{api_scope: "profile:read"})

    # The profile sections, same doc shape as the public .json pages (the
    # email list is viewer-aware). Which section a route means travels in
    # the route assigns.
    for section <- ~w(work_experiences links social_media_accounts addresses
                      phone_numbers emails tags languages qualifications)a do
      get("/users/:slug/#{section}", SectionController, :index,
        assigns: %{section: section, api_scope: "profile:read"}
      )
    end

    # Writes on the authorized user's own sections. No email routes (an
    # address is a PIN-verified identity); tags go through TagController.
    for section <- ~w(work_experiences links social_media_accounts addresses
                      phone_numbers languages qualifications)a do
      post("/me/#{section}", SectionController, :create,
        assigns: %{section: section, api_scope: "profile:write"}
      )

      patch("/me/#{section}/:id", SectionController, :update,
        assigns: %{section: section, api_scope: "profile:write"}
      )

      delete("/me/#{section}/:id", SectionController, :delete,
        assigns: %{section: section, api_scope: "profile:write"}
      )
    end

    post("/me/tags", TagController, :create, assigns: %{api_scope: "profile:write"})
    delete("/me/tags/:id", TagController, :delete, assigns: %{api_scope: "profile:write"})

    # Pending post images (multipart upload; attach via image_ids in
    # POST /posts, swept after a day if left unattached).
    post("/me/post_images", ImageController, :create, assigns: %{api_scope: "posts:write"})
    delete("/me/post_images/:id", ImageController, :delete, assigns: %{api_scope: "posts:write"})

    # The social graph: people lists (same doc shape as the public .json
    # pages), the viewer's standing with a member, and follow/unfollow. Vernetzt
    # is a mutual follow now, so there is no separate connection lifecycle —
    # following someone who follows you back makes you vernetzt.
    for route <- ~w(followers following connections relationship)a do
      get("/users/:slug/#{route}", SocialController, route, assigns: %{api_scope: "social:read"})
    end

    put("/users/:slug/follow", SocialController, :follow, assigns: %{api_scope: "social:write"})

    delete("/users/:slug/follow", SocialController, :unfollow,
      assigns: %{api_scope: "social:write"}
    )

    # Posts: the member's feed, the author archive, permalinks, composing,
    # replies and the idempotent engagement switches.
    get("/feed", PostController, :feed, assigns: %{api_scope: "posts:read"})
    get("/users/:slug/posts", PostController, :archive, assigns: %{api_scope: "posts:read"})
    get("/posts/:id", PostController, :show, assigns: %{api_scope: "posts:read"})

    get("/posts/:id/engagement", PostController, :engagement, assigns: %{api_scope: "posts:read"})

    post("/posts", PostController, :create, assigns: %{api_scope: "posts:write"})
    post("/posts/:id/replies", PostController, :reply, assigns: %{api_scope: "posts:write"})
    patch("/posts/:id", PostController, :update, assigns: %{api_scope: "posts:write"})
    delete("/posts/:id", PostController, :delete, assigns: %{api_scope: "posts:write"})

    for kind <- ~w(like bookmark repost)a do
      put("/posts/:id/#{kind}", PostController, :engage,
        assigns: %{engagement: kind, api_scope: "posts:write"}
      )

      delete("/posts/:id/#{kind}", PostController, :disengage,
        assigns: %{engagement: kind, api_scope: "posts:write"}
      )
    end

    # Direct messages (the request model, blocking and freezes apply like
    # on the website) and the derived notification feed.
    get("/conversations", MessageController, :index, assigns: %{api_scope: "messages:read"})

    get("/conversations/:id/messages", MessageController, :messages,
      assigns: %{api_scope: "messages:read"}
    )

    post("/conversations/:id/messages", MessageController, :create_message,
      assigns: %{api_scope: "messages:write"}
    )

    post("/conversations/:id/accept", MessageController, :accept,
      assigns: %{api_scope: "messages:write"}
    )

    post("/conversations/:id/decline", MessageController, :decline,
      assigns: %{api_scope: "messages:write"}
    )

    post("/conversations/:id/read", MessageController, :mark_read,
      assigns: %{api_scope: "messages:write"}
    )

    post("/users/:slug/messages", MessageController, :send_to_user,
      assigns: %{api_scope: "messages:write"}
    )

    # Notifications span the social areas, so they ride on the social scopes.
    get("/notifications", NotificationController, :index, assigns: %{api_scope: "social:read"})

    post("/notifications/read", NotificationController, :mark_read,
      assigns: %{api_scope: "social:write"}
    )

    # JSON 404 for unknown API paths — without this they would fall through
    # to the HTML profile routes. Also the CORS preflight's match. The one
    # route that legitimately needs no scope.
    match(:*, "/*path", NotFoundController, :show, assigns: %{api_scope: :none})
  end

  # The member's own editing world, user-agnostic: every /settings/* page
  # operates on the logged-in member (the :settings_pipe pipeline assigns
  # :user = :current_user), so any of these URLs can be handed to any member —
  # "open vutuv.de/settings/links" — and opens *their own* editor. The
  # /:slug/... twins in the scope below stay the pure public showcase view.
  # Must stay ABOVE the /:slug catch-all scope ("settings" is also a reserved
  # slug, so no member can claim it).
  scope "/settings", VutuvWeb do
    pipe_through([:browser, :settings_pipe])

    # The hub: the one grouped map of everything a member can change.
    get("/", SettingsController, :index)

    # The profile basics (photos, name, about you) — the old /:slug/edit.
    get("/profile", UserController, :edit)
    put("/profile", UserController, :update)
    patch("/profile", UserController, :update)

    # The account areas: sign-in & security, language & display, your data, and
    # the delete-account danger page. put + patch both, to match whichever
    # method <.form for={changeset} emits for a persisted record.
    get("/security", SettingsController, :security)
    get("/preferences", SettingsController, :preferences)
    get("/delete", SettingsController, :delete_account)
    get("/privacy", SettingsController, :privacy)
    put("/privacy", SettingsController, :update_privacy)
    patch("/privacy", SettingsController, :update_privacy)
    get("/fediverse", SettingsController, :fediverse)
    put("/fediverse", SettingsController, :update_fediverse)
    patch("/fediverse", SettingsController, :update_fediverse)
    get("/notifications", SettingsController, :notifications)
    put("/notifications", SettingsController, :update_notifications)
    patch("/notifications", SettingsController, :update_notifications)
    # The member's "Your organizations" hub: the organization pages they own or
    # help run, the explainer of how organizations work, and the add call to
    # action. The public browse directory stays at /organizations.
    get("/organizations", SettingsController, :organizations)
    # Read-only developer hub: connected apps + personal API tokens.
    get("/apps", SettingsController, :apps)
    put("/language", SettingsController, :update_language)
    patch("/language", SettingsController, :update_language)
    put("/maps", SettingsController, :update_maps)
    patch("/maps", SettingsController, :update_maps)
    put("/post_display", SettingsController, :update_post_display)
    patch("/post_display", SettingsController, :update_post_display)
    # Clear a whole preference group back to nil = "inherit the installation
    # default" (Vutuv.Prefs) — the quiet reset links under the two cards.
    post("/post_display/reset", SettingsController, :reset_post_display)
    post("/maps/reset", SettingsController, :reset_maps)
    # Signed-in devices: DELETE one by id, or all-but-this-one (issue #794).
    delete("/devices/:id", SettingsController, :revoke_session)
    delete("/devices", SettingsController, :revoke_other_sessions)
    # Passkeys (issue #795): the WebAuthn registration ceremony is
    # challenge → create (both JSON), plus remove-by-id.
    post("/passkeys/challenge", PasskeyController, :challenge)
    post("/passkeys", PasskeyController, :create)
    delete("/passkeys/:id", PasskeyController, :delete)
    # The power-user login codes (issue #912): set up / turn off the
    # authenticator app (TOTP), and view / (re)generate / delete the printed
    # one-time code list. Both work in the login PIN field.
    get("/totp/new", TotpController, :new)
    post("/totp", TotpController, :create)
    delete("/totp", TotpController, :delete)
    get("/login_codes", LoginCodeController, :index)
    post("/login_codes", LoginCodeController, :create)
    delete("/login_codes", LoginCodeController, :delete)
    # The export area moved to the profile (/:slug/export, where issue #841
    # put the formatted CV beside the GDPR download); the settings-era URLs
    # redirect so bookmarks keep working.
    get("/export", SettingsController, :export_redirect)
    get("/export/download", SettingsController, :export_download_redirect)
    # "Ihre Daten" was split into Import and Export (its two rows); redirect
    # the short-lived drawer URL to the hub.
    get("/data", SettingsController, :data_redirect)
    # Import a LinkedIn data-export ZIP: upload -> preview -> apply the picks.
    get("/import/linkedin", ImportController, :new)
    post("/import/linkedin", ImportController, :create)
    post("/import/linkedin/apply", ImportController, :confirm)
    # Changing the username: the form, the POST, and the live availability
    # check behind the form's as-you-type verdict.
    get("/usernames/availability", UsernameController, :availability)
    resources("/usernames", UsernameController, only: [:new, :create], as: :settings_username)

    # The profile-content section editors, each mirroring its public
    # /:slug/<section> twin. `manage` is the editor index (add tile, reorder,
    # row actions, inside the settings shell); new/create/edit/update/delete
    # live only here — the /:slug routes serve just the public index + show.
    get("/emails", EmailController, :manage)
    # PIN-entry step for the email-change flow (issue #759).
    post("/emails/confirmation", EmailController, :confirm)

    resources("/emails", EmailController,
      only: [:new, :create, :edit, :update, :delete],
      as: :settings_email
    )

    get("/phone_numbers", PhoneNumberController, :manage)

    resources("/phone_numbers", PhoneNumberController,
      only: [:new, :create, :edit, :update, :delete],
      as: :settings_phone_number
    )

    get("/links", UrlController, :manage)

    # "This link is my webpage" verification: the owner-only page that shows the
    # rel=me / DNS / well-known instructions, and the POST that runs the check.
    get("/links/:id/verify", UrlController, :verify)
    post("/links/:id/verify", UrlController, :run_verify)

    resources("/links", UrlController,
      only: [:new, :create, :edit, :update, :delete],
      as: :settings_link
    )

    get("/social_media_accounts", SocialMediaAccountController, :manage)

    resources("/social_media_accounts", SocialMediaAccountController,
      only: [:new, :create, :edit, :update, :delete],
      as: :settings_social_media_account
    )

    # Pin one work experience as the profile job title, or clear back to the
    # automatic heuristic (issue #833).
    put("/work_experiences/:id/pin", WorkExperienceController, :pin)
    delete("/work_experiences/:id/pin", WorkExperienceController, :unpin)
    get("/work_experiences", WorkExperienceController, :manage)

    # The editor's verified-organization link suggestion (issue #931), a JSON match
    # for the organization being typed. Before the resources so "organization_suggestions"
    # is not read as a work-experience id.
    get(
      "/work_experiences/organization_suggestions",
      WorkExperienceController,
      :organization_suggestions
    )

    resources("/work_experiences", WorkExperienceController,
      only: [:new, :create, :edit, :update, :delete],
      as: :settings_work_experience
    )

    get("/educations", EducationController, :manage)

    resources("/educations", EducationController,
      only: [:new, :create, :edit, :update, :delete],
      as: :settings_education
    )

    get("/languages", LanguageController, :manage)

    resources("/languages", LanguageController,
      only: [:new, :create, :edit, :update, :delete],
      as: :settings_language
    )

    get("/qualifications", QualificationController, :manage)

    resources("/qualifications", QualificationController,
      only: [:new, :create, :edit, :update, :delete],
      as: :settings_qualification
    )

    get("/addresses", AddressController, :manage)

    resources("/addresses", AddressController,
      only: [:new, :create, :edit, :update, :delete],
      as: :settings_address
    )

    get("/tags", UserTagController, :manage)
    # The add-tag form (new) is VutuvWeb.TagNewLive (the live_session above),
    # which also saves over its socket, so there is no dead create action any
    # more (issue #877 removed the tag page's "Add this tag" button, its only
    # plain-HTTP caller). Delete is the sole remaining REST action here.
    resources("/tags", UserTagController, only: [:delete], as: :settings_tag)
  end

  # Profiles live at the URL root: /:slug is the profile page, /:slug/... the
  # per-user sub-pages. This scope must stay LAST — every route above wins by
  # definition order, and Vutuv.Accounts.ReservedSlugs keeps users from
  # claiming those path words as slugs. Everything under /:slug is the PUBLIC
  # showcase view (or a redirect into /settings); editing happens in the
  # /settings scope above.
  scope "/", VutuvWeb do
    pipe_through(:browser)

    # No :index — the public member directory lives at /members
    # (DirectoryController), so UserController never lists. No :new/:create either —
    # registration is the landing-page form (POST /new_registration); the
    # UserController versions were unreachable (EnsureActivated 404'd them).
    # No :edit/:update — the basics form lives at /settings/profile now.
    resources "/", UserController,
      param: "slug",
      except: [:index, :new, :create, :edit, :update] do
      pipe_through(:user_pipe)
      # The old owner URLs: everything editable moved to the user-agnostic
      # /settings scope. Redirect so bookmarks and muscle memory keep working.
      get("/edit", UserController, :edit_redirect)
      get("/settings", SettingsController, :legacy_redirect)
      get("/settings/*rest", SettingsController, :legacy_redirect)
      # The session-aware vCard (all emails for the owner / a follower-back
      # viewer); the anonymous canonical vCard is /:slug.vcf.
      get("/vcard", VCardController, :get)
      # The owner-only GDPR data export (RequireLogin + AuthUser in the
      # controller): the overview page + the one-JSON-file download.
      get("/export", ExportController, :index)
      get("/export/download", ExportController, :download)
      # The public, viewer-scoped CV / Lebenslauf (issue #841): the
      # interactive builder LiveView, the print-ready view (the PDF path via
      # the browser print dialog) and the file downloads (docx/odt/html/tex/
      # json). Every part is include/excludable, so a recruiter can tailor or
      # anonymize the CV; the selection rides along as ?hide=<keys>.
      get("/cv", CVController, :show)
      get("/cv/print", CVController, :print)
      get("/cv/download/:format", CVController, :download)
      resources("/emails", EmailController, only: [:index, :show])
      resources("/followers", FollowerController, only: [:index])
      resources("/following", FolloweeController, only: [:index])
      resources("/connections", ConnectionController, only: [:index])

      resources("/user_tag_endorsements", UserTagEndorsementController,
        only: [:create, :delete],
        as: :tag_endorsement
      )

      resources("/phone_numbers", PhoneNumberController, only: [:index, :show])
      resources("/links", UrlController, only: [:index, :show])
      resources("/social_media_accounts", SocialMediaAccountController, only: [:index, :show])
      resources("/work_experiences", WorkExperienceController, only: [:index, :show])
      resources("/educations", EducationController, only: [:index, :show])
      resources("/languages", LanguageController, only: [:index, :show])
      resources("/qualifications", QualificationController, only: [:index, :show])
      resources("/addresses", AddressController, only: [:index, :show])
      resources("/tags", UserTagController, only: [:index, :show], as: :tag)

      # The public list of everyone who endorses this member for one tag (the
      # profile Tags popover's "and N more" link). It lives under the user-tag
      # show path; `:id` is the tag slug, resolved by UserTagController's
      # ResolveOwnedSlug plug exactly like :show. Served as HTML + the agent
      # formats (.md/.txt/.json/.xml), so a single GET covers them all.
      get("/tags/:id/endorsers", UserTagController, :endorsers)
    end

    # The author's post archive — whole, or scoped to a year / month / day —
    # and the post permalinks (/:slug/posts/<uuid-v7>). Everything
    # post-related lives under the fixed /posts segment. The router cannot
    # tell a year from a post id, so the single extra segment is one route
    # and the controller dispatches on its shape (UUID = permalink, anything
    # else = year archive or 404).
    get("/:slug/posts", PostController, :index)
    get("/:slug/posts/:id", PostController, :show)
    get("/:slug/posts/:year/:month", PostController, :index)
    get("/:slug/posts/:year/:month/:day", PostController, :index)
  end
end
