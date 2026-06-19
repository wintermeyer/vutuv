defmodule VutuvWeb.Router do
  use VutuvWeb, :router
  alias VutuvWeb.Plug, as: Plugs

  if Mix.env() == :dev do
    forward("/sent_emails", Plug.Swoosh.MailboxPreview)
  end

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_flash)
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
    get("/listings/most_followed_users", PageController, :most_followed_users)
    get("/new_registration", PageController, :redirect_index)
    post("/new_registration", PageController, :new_registration)

    resources("/follows", FollowController, only: [:create, :delete])

    # Liking / bookmarking a *member* (the private, silent save the profile
    # header offers, the people-equivalent of a post like/bookmark). POST to
    # save, DELETE /:id (the target member's id) to remove. Logged-in only
    # (checked in the controller).
    post("/user_bookmarks", UserSaveController, :bookmark)
    delete("/user_bookmarks/:id", UserSaveController, :unbookmark)
    post("/user_likes", UserSaveController, :like)
    delete("/user_likes/:id", UserSaveController, :unlike)

    # The mutual-connection lifecycle (the list lives at /:slug/connections in
    # the profile scope below). create = request, then accept/decline/withdraw.
    post("/connections", ConnectionController, :create)
    post("/connections/:id/accept", ConnectionController, :accept)
    post("/connections/:id/decline", ConnectionController, :decline)
    delete("/connections/:id", ConnectionController, :delete)

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

      # The newsfeed and the post editor ("feed"/"posts" are in
      # ReservedSlugs). Auth is checked in the mounts.
      live("/feed", PostLive.Feed, :index)
      live("/posts/:id/edit", PostLive.Edit, :edit)
      live("/posts/:id/reply", PostLive.Reply, :new)

      # The private likes / bookmarks lists (reserved slugs too).
      live("/likes", PostLive.Saved, :likes)
      live("/bookmarks", PostLive.Saved, :bookmarks)
    end
  end

  scope "/admin", VutuvWeb.Admin, as: :admin do
    pipe_through([:browser, :admin])
    resources("/", AdminController, only: [:index])

    # The daily activity report: confirmed-by-PIN registrations and the day's
    # posts, reposts, likes and bookmarks. ?date time-travels to any past day;
    # Vutuv.Reports.DailyReporter mails the previous day's copy each night.
    get("/reports", ReportController, :index)

    # The moderation queue + rulings. /reporters (the misuse dashboard) must
    # precede /:id so the literal segment wins.
    get("/moderation", ModerationController, :index)
    get("/moderation/reporters", ModerationController, :reporters)
    get("/moderation/:id", ModerationController, :show)
    get("/moderation/:id/evidence", ModerationController, :evidence)
    post("/moderation/:id/uphold", ModerationController, :uphold)
    post("/moderation/:id/reject", ModerationController, :reject)

    # The ad review dashboard: every booked ad is approved here before it
    # serves (see Vutuv.Ads.approve_ad/2). :show is the per-ad detail page.
    get("/ads", AdController, :index)
    get("/ads/:id", AdController, :show)
    post("/ads/:id/approve", AdController, :approve)

    post("/slugs", SlugController, :update)
    post("/users", UserController, :update)
    resources("/locales", LocaleController, only: [:index, :show])
    resources("/exonyms", ExonymController)

    resources("/tags", TagController, param: "slug")

    # The registered OAuth apps + the bad-player kill switch.
    get("/api_apps", ApiAppController, :index)
    post("/api_apps/:id/suspend", ApiAppController, :suspend)
    post("/api_apps/:id/unsuspend", ApiAppController, :unsuspend)
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
                      phone_numbers emails tags)a do
      get("/users/:slug/#{section}", SectionController, :index,
        assigns: %{section: section, api_scope: "profile:read"}
      )
    end

    # Writes on the authorized user's own sections. No email routes (an
    # address is a PIN-verified identity); tags go through TagController.
    for section <- ~w(work_experiences links social_media_accounts addresses
                      phone_numbers)a do
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
    # pages), the viewer's standing with a member, follow/unfollow and the
    # connection lifecycle.
    for route <- ~w(followers following connections relationship)a do
      get("/users/:slug/#{route}", SocialController, route, assigns: %{api_scope: "social:read"})
    end

    put("/users/:slug/follow", SocialController, :follow, assigns: %{api_scope: "social:write"})

    delete("/users/:slug/follow", SocialController, :unfollow,
      assigns: %{api_scope: "social:write"}
    )

    post("/users/:slug/connection", SocialController, :request_connection,
      assigns: %{api_scope: "social:write"}
    )

    post("/connections/:id/accept", SocialController, :accept_connection,
      assigns: %{api_scope: "social:write"}
    )

    post("/connections/:id/decline", SocialController, :decline_connection,
      assigns: %{api_scope: "social:write"}
    )

    delete("/connections/:id", SocialController, :remove_connection,
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

  # Profiles live at the URL root: /:slug is the profile page, /:slug/... the
  # per-user sub-pages. This scope must stay LAST — every route above wins by
  # definition order, and Vutuv.Accounts.ReservedSlugs keeps users from
  # claiming those path words as slugs.
  scope "/", VutuvWeb do
    pipe_through(:browser)

    # No :index — there is no public user directory; the admin panel lists
    # unverified users and search covers discovery. No :new/:create either —
    # registration is the landing-page form (POST /new_registration); the
    # UserController versions were unreachable (EnsureActivated 404'd them).
    resources "/", UserController, param: "slug", except: [:index, :new, :create] do
      pipe_through(:user_pipe)
      # The owner's personal data download (GDPR): one JSON file. Owner-only,
      # enforced by the controller's RequireLogin + AuthUser plugs.
      get("/export", ExportController, :show)
      # The session-aware vCard (all emails for the owner / a follower-back
      # viewer); the anonymous canonical vCard is /:slug.vcf.
      get("/vcard", VCardController, :get)
      resources("/emails", EmailController)
      # PIN-entry step for the email-change flow (issue #759).
      post("/emails/confirmation", EmailController, :confirm)
      # Changing the username: the form, the POST, and the live
      # availability check behind the form's as-you-type verdict.
      get("/slugs/availability", SlugController, :availability)
      resources("/slugs", SlugController, only: [:new, :create])

      # Account settings, split off the old single edit form into focused,
      # owner-only pages (SettingsController). put + patch both, to match
      # whichever method <.form for={changeset} emits for a persisted record.
      get("/settings", SettingsController, :index)
      get("/settings/privacy", SettingsController, :privacy)
      put("/settings/privacy", SettingsController, :update_privacy)
      patch("/settings/privacy", SettingsController, :update_privacy)
      get("/settings/notifications", SettingsController, :notifications)
      put("/settings/notifications", SettingsController, :update_notifications)
      patch("/settings/notifications", SettingsController, :update_notifications)
      # Read-only developer hub: connected apps + personal API tokens, split off
      # the account hub so neither page is overloaded.
      get("/settings/apps", SettingsController, :apps)
      # The interface-language form lives on the account hub (GET /settings); it
      # only needs a write target, not its own page.
      put("/settings/language", SettingsController, :update_language)
      patch("/settings/language", SettingsController, :update_language)
      # Signed-in devices: the list lives on the account hub (GET /settings).
      # DELETE one device by id, or all-but-this-one (issue #794).
      delete("/settings/devices/:id", SettingsController, :revoke_session)
      delete("/settings/devices", SettingsController, :revoke_other_sessions)
      # Passkeys (issue #795): enrol from the account hub (the WebAuthn
      # registration ceremony is challenge → create, both JSON) and remove one
      # by id. The list itself renders on GET /settings. Owner-only, like the
      # rest of this controller — a passkey can only be added while logged in.
      post("/settings/passkeys/challenge", PasskeyController, :challenge)
      post("/settings/passkeys", PasskeyController, :create)
      delete("/settings/passkeys/:id", PasskeyController, :delete)
      resources("/followers", FollowerController, only: [:index])
      resources("/following", FolloweeController, only: [:index])
      resources("/connections", ConnectionController, only: [:index])

      resources("/user_tag_endorsements", UserTagEndorsementController,
        only: [:create, :delete],
        as: :tag_endorsement
      )

      resources("/phone_numbers", PhoneNumberController)
      resources("/links", UrlController)
      resources("/social_media_accounts", SocialMediaAccountController)
      resources("/work_experiences", WorkExperienceController)
      resources("/addresses", AddressController)

      resources("/tags", UserTagController,
        only: [:new, :create, :show, :delete, :index],
        as: :tag
      )
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
