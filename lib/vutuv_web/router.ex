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
    plug(Plugs.ConfigureSession, repo: Vutuv.Repo)
    plug(Plugs.Locale)
  end

  pipeline :user_pipe do
    plug(Plugs.UserResolveSlug)
    plug(Plugs.EnsureValidated)
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

    resources("/search_queries", SearchQueryController, only: [:create, :new, :show])

    resources "/users", UserController, param: "slug" do
      pipe_through(:user_pipe)
      resources("/emails", EmailController)
      # PIN-entry step for the email-change flow (issue #759).
      post("/emails/confirmation", EmailController, :confirm)
      resources("/slugs", SlugController, only: [:index, :new, :create, :show, :update])
      resources("/groups", GroupController)
      resources("/followers", FollowerController, only: [:index])
      resources("/followees", FolloweeController, only: [:index])

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

      resources "/job_postings", JobPostingController, param: "job_slug" do
        resources("/tags", JobPostingTagController,
          as: :tag,
          only: [:index, :new, :create, :delete]
        )
      end

      resources("/recruiter_subscriptions", RecruiterSubscriptionController,
        only: [:index, :new, :create]
      )
    end

    post("/users/:slug/tags_create", UserController, :tags_create)
    # PIN-entry step for the account-deletion flow (issue #759).
    post("/account_deletion", UserController, :confirm_delete)

    resources("/sessions", SessionController, only: [:new, :create, :delete])
    get("/follow_back/:id", UserController, :follow_back)
  end

  scope "/admin", VutuvWeb.Admin, as: :admin do
    pipe_through(:browser)
    resources("/", AdminController, only: [:index])
    post("/slugs", SlugController, :update)
    post("/users", UserController, :update)
    resources("/locales", LocaleController, only: [:index, :show])
    resources("/exonyms", ExonymController)

    resources("/tags", TagController, param: "slug")

    resources("/recruiter_packages", RecruiterPackageController, param: "package_slug")
    resources("/coupons", CouponController)
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

  scope "/", as: :default do
    pipe_through(:browser)
    get("/:slug", VutuvWeb.PageController, :redirect_user)
  end
end
