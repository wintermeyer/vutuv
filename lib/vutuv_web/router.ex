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
    plug(:put_root_layout, html: {VutuvWeb.LayoutHTML, :root})
    plug(Plugs.ConfigureSession, repo: Vutuv.Repo)
    plug(Plugs.Locale)
  end

  pipeline :user_pipe do
    # Keep the per-user detail pages (phone numbers, emails, addresses, …) out
    # of search indexes. Runs first so the header is present even when a later
    # plug halts (e.g. an unknown slug 404s). The profile page itself (/:slug)
    # does not go through this pipeline and stays crawlable.
    plug(Plugs.NoIndex)
    plug(Plugs.UserResolveSlug)
    plug(Plugs.EnsureValidated)
  end

  # Gates the whole /admin scope in one place, so a new admin controller
  # cannot forget the auth plugs and ship world-accessible.
  pipeline :admin do
    plug(Plugs.RequireLogin)
    plug(Plugs.AuthAdmin)
  end

  pipeline :api do
    plug(:accepts, ["json-api"])
    plug(Plugs.PutAPIHeaders)
    plug(Plugs.Locale)
  end

  pipeline :render_404 do
    plug(Plugs.All404)
  end

  # Served from the app (not priv/static, which is gitignored) and with no
  # pipeline so crawlers that send "Accept: text/plain" are not turned away
  # by the browser pipeline's `accepts ["html"]`.
  scope "/", VutuvWeb do
    get("/robots.txt", PageController, :robots)
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

    resources("/memberships", MembershipController, only: [:create, :delete])

    resources "/connections", ConnectionController, only: [:create, :delete] do
      resources("/memberships", MembershipController, only: [:create, :delete])
    end

    # Search lives at /search: GET renders the form, POST runs a query, and
    # /search/:id shows a stored query (the id is the query value itself).
    get("/search", SearchQueryController, :new)
    post("/search", SearchQueryController, :create)
    get("/search/:id", SearchQueryController, :show)

    # Login/logout under the names humans type. The controller still speaks
    # "session": POST /login handles both PIN steps, DELETE /logout signs out.
    get("/login", SessionController, :new)
    post("/login", SessionController, :create)
    delete("/logout", SessionController, :delete)

    # PIN-entry step for the account-deletion flow (issue #759).
    post("/account_deletion", UserController, :confirm_delete)
    get("/follow_back/:id", UserController, :follow_back)

    # The authorizing post-image proxy: every post-image byte goes through
    # the app so the post's audience guards its images too. `:version` is
    # e.g. "feed.webp"; nginx only streams what this controller approves.
    get("/post_images/:token/:version", PostImageController, :show)

    # Post deletion (the permalink lives in the profile scope below; "posts"
    # is in ReservedSlugs).
    delete("/posts/:id", PostController, :delete)
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
      live("/messages", MessageLive.Index, :index)
      live("/messages/:id", MessageLive.Index, :show)

      # The newsfeed and the post editor ("feed"/"posts" are in
      # ReservedSlugs). Auth is checked in the mounts.
      live("/feed", PostLive.Feed, :index)
      live("/posts/:id/edit", PostLive.Edit, :edit)
    end
  end

  scope "/admin", VutuvWeb.Admin, as: :admin do
    pipe_through([:browser, :admin])
    resources("/", AdminController, only: [:index])
    post("/slugs", SlugController, :update)
    post("/users", UserController, :update)
    resources("/locales", LocaleController, only: [:index, :show])
    resources("/exonyms", ExonymController)

    resources("/tags", TagController, param: "slug")
  end

  scope "/api/1.0/", as: :api do
    pipe_through(:api)

    # `only: []`: the user collection and a single user are intentionally not
    # exposed over the API; this resource exists purely to namespace the
    # read-only nested sub-resources below. `param: "slug"` must stay so the
    # nested param remains `:user_slug` (resolved by UserResolveSlug).
    resources "/users", VutuvWeb.Api.UserController, param: "slug", only: [] do
      pipe_through(:user_pipe)
      get("/vcard", VutuvWeb.Api.VCardController, :get)

      resources("/emails", VutuvWeb.Api.EmailController, only: [:index, :show])

      # resources "/slugs", VutuvWeb.Api.SlugController, only: [:index, :show]  # Controller does not exist

      resources("/groups", VutuvWeb.Api.GroupController, only: [:index, :show])
      resources("/followers", VutuvWeb.Api.FollowerController, only: [:index])
      resources("/followees", VutuvWeb.Api.FolloweeController, only: [:index])

      resources("/phone_numbers", VutuvWeb.Api.PhoneNumberController, only: [:index, :show])
      resources("/links", VutuvWeb.Api.UrlController, only: [:index, :show])

      resources("/social_media_accounts", VutuvWeb.Api.SocialMediaAccountController,
        only: [:index, :show]
      )

      resources("/work_experiences", VutuvWeb.Api.WorkExperienceController, only: [:index, :show])
      resources("/addresses", VutuvWeb.Api.AddressController, only: [:index, :show])

      # resources "/search_terms", VutuvWeb.Api.SearchTermController, only: [:index, :show]  # Controller does not exist
    end

    pipe_through(:render_404)
  end

  # Profiles live at the URL root: /:slug is the profile page, /:slug/... the
  # per-user sub-pages. This scope must stay LAST — every route above wins by
  # definition order, and Vutuv.Accounts.ReservedSlugs keeps users from
  # claiming those path words as slugs.
  scope "/", VutuvWeb do
    pipe_through(:browser)

    post("/:slug/tags_create", UserController, :tags_create)

    # No :index — there is no public user directory; the admin panel lists
    # unverified users and search covers discovery. No :new/:create either —
    # registration is the landing-page form (POST /new_registration); the
    # UserController versions were unreachable (EnsureValidated 404'd them).
    resources "/", UserController, param: "slug", except: [:index, :new, :create] do
      pipe_through(:user_pipe)
      resources("/emails", EmailController)
      # PIN-entry step for the email-change flow (issue #759).
      post("/emails/confirmation", EmailController, :confirm)
      resources("/slugs", SlugController, only: [:index, :new, :create, :show, :update])
      resources("/groups", GroupController)
      resources("/followers", FollowerController, only: [:index])
      resources("/following", FolloweeController, only: [:index])

      resources("/user_tag_endorsements", UserTagEndorsementController,
        only: [:create, :delete],
        as: :tag_endorsement
      )

      resources("/phone_numbers", PhoneNumberController)
      # resources "/dates", DateController  # Controller does not exist
      resources("/links", UrlController)
      resources("/social_media_accounts", SocialMediaAccountController)
      resources("/work_experiences", WorkExperienceController)
      resources("/addresses", AddressController)
      # resources "/oauth_providers", OAuthProviderController  # Controller does not exist
      resources("/search_terms", SearchTermController, only: [:show, :index])

      resources("/tags", UserTagController,
        only: [:new, :create, :show, :delete, :index],
        as: :tag
      )
    end

    # The author's post archive — whole, or scoped to a year / month / day —
    # and the post permalinks (/:slug/posts/2026/06/05/1). Everything
    # post-related lives under the fixed /posts segment; the controller 404s
    # date segments that do not parse.
    get("/:slug/posts", PostController, :index)
    get("/:slug/posts/:year", PostController, :index)
    get("/:slug/posts/:year/:month", PostController, :index)
    get("/:slug/posts/:year/:month/:day", PostController, :index)
    get("/:slug/posts/:year/:month/:day/:seq", PostController, :show)
  end
end
