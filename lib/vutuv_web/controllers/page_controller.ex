defmodule VutuvWeb.PageController do
  use VutuvWeb, :controller
  plug(:display_pin_entry when action in [:index])
  plug(VutuvWeb.Plug.RequireUserLoggedOut when action in [:index])
  alias Vutuv.Accounts.Email
  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.SourceRepo
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.ListDocs
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.LandingExperiment
  alias VutuvWeb.RateLimit

  def index(conn, _params) do
    # Sign-up form defaults: pre-check "show on profile" (public?: true) and
    # preselect the "Personal" email type (most people sign up with their
    # private address). These prime the form's controls only - the User/Email
    # schemas keep their own defaults for every other code path, so an address
    # created without an explicit choice still stays private.
    #
    # The gender question is the one control deliberately left UNSET, and it is
    # the only field on this form where that is a decision rather than an
    # omission. This exact group was once preselected to "männlich", so every
    # woman signing up had to correct an assumption about herself before typing
    # her name, and members wrote in about it. Nothing may fill it in for them:
    # an unset group asks, a preselected one assumes.
    #
    # The Fediverse box is pre-checked the same way: most people who join want
    # the connection to Mastodon and friends, and sign-up is the one moment
    # every member passes through, while the switch on /settings/fediverse is
    # one hardly anybody goes looking for. It stays a visible question with a
    # line of explanation next to it, and unticking it is one click. Primed to
    # `false` where the installation federates nothing at all
    # (FEDIVERSE_ENABLED=false, intranets), which is also where the template
    # leaves the whole question out.
    #
    # One question, all three switches: a ticked box is expanded by
    # `expand_fediverse_choice/1` below into taking part *plus* the reactions
    # and replies that come back, because that is what "take part" means to
    # somebody reading it, and the box's own text says so.
    changeset =
      %User{fediverse_followers?: Fediverse.enabled?()}
      |> User.changeset()
      |> Ecto.Changeset.put_assoc(:emails, [%Email{public?: true, email_type: "Personal"}])

    prefetch = "/listings/most_followed_users"

    # The headline is under a split test (VutuvWeb.LandingExperiment): the
    # variant is drawn once per session and one view is counted with it.
    conn
    |> LandingExperiment.assign_variant()
    |> render_landing(changeset: changeset, prefetch: prefetch)
  end

  # The one way to render the landing page, because it is rendered from two
  # actions: `index` and the rejected sign-up below, which shows the identical
  # screen with the errors on it. Assigning the examples in `index` only left
  # the rejected sign-up raising KeyError on the first assign the template
  # reached, i.e. a 500 on every mistyped form.
  defp render_landing(conn, assigns) do
    # Every example on this page is a static screenshot in the template, so the
    # landing page loads nothing of its own. It used to show a wall of real
    # posts from a cached snapshot; that came out again because a socket and a
    # refresh query on the most requested page in the app were not worth what
    # the block added.
    render(
      conn,
      "index.html",
      Keyword.merge(
        [prefetch: "/listings/most_followed_users"],
        assigns
      )
    )
  end

  def redirect_index(conn, _params) do
    redirect(conn, to: ~p"/")
  end

  # The community guidelines (the "family-friendly" house rules) that the
  # report form, the moderation emails and the footer link to.
  def community(conn, _params) do
    render(conn, "community.html", page_title: gettext("Community guidelines"))
  end

  @doc """
  Serves robots.txt from the application rather than a static file.

  `priv/static` is gitignored in this project, so a code route keeps the
  policy under version control. The content lives in `VutuvWeb.RobotsTxt`,
  rendered for the configured AI-crawler stance (`VutuvWeb.ContentPolicy`).
  """
  def robots(conn, _params) do
    conn
    |> discovery_cache_headers()
    |> put_resp_content_type("text/plain")
    |> send_resp(200, robots_body(conn))
  end

  # The tag host answers with its own, much shorter file: it carries topic
  # addresses and nothing anybody reads, so the document has one thing to say
  # (see `VutuvWeb.RobotsTxt.tag_host/0`, including why it does not say
  # `Disallow: /`).
  defp robots_body(conn) do
    if Fediverse.tag_host?(conn.host),
      do: VutuvWeb.RobotsTxt.tag_host(),
      else: VutuvWeb.RobotsTxt.render(VutuvWeb.ContentPolicy.policy())
  end

  @doc """
  The web app manifest (issue #1464): what this site is once somebody installs
  it on a phone's Home Screen or launcher.

  The load-bearing key is `scope`. iOS decides from it which links stay inside
  the installed app — "links outside the scope will open in Safari View
  Controller" (Apple, WWDC23) — and shipping no manifest at all is what put
  that overlay browser on top of the app for the member who reported #1464.
  `"/"` claims the whole site, so every in-app link stays in the app and only
  a genuinely foreign URL leaves it.

  It is generated rather than served as a static file for the same reason
  robots.txt is (`priv/static` is gitignored), and because the name on
  somebody's Home Screen belongs to the installation, not to us: it is the
  `:node_name` this installation already introduces itself with elsewhere.

  The icons are rendered from `priv/static/favicon.svg`
  (`rsvg-convert -w 512 -h 512 priv/static/favicon.svg -o …`). The maskable
  one is the same artwork with the glyph scaled to 75% about the centre, so
  Android's launcher shape can crop it to a circle without cutting the "v" —
  without a maskable icon the whole square is shrunk inside the shape instead,
  which reads as a sticker rather than an app icon.
  """
  def webmanifest(conn, _params) do
    conn
    |> discovery_cache_headers()
    |> put_resp_content_type("application/manifest+json")
    |> send_resp(200, Jason.encode!(web_app_manifest()))
  end

  defp web_app_manifest do
    name = Application.fetch_env!(:vutuv, :node_name)

    %{
      id: "/",
      name: name,
      short_name: name,
      start_url: "/",
      scope: "/",
      display: "standalone",
      # The splash screen behind the app while it starts, and the launcher
      # background: the page canvas (slate-50) and the light theme-color the
      # document already ships, so the start does not flash a colour the app
      # never shows.
      background_color: "#f8fafc",
      theme_color: "#ffffff",
      icons: [
        %{src: "/images/icon-192.png", sizes: "192x192", type: "image/png", purpose: "any"},
        %{src: "/images/icon-512.png", sizes: "512x512", type: "image/png", purpose: "any"},
        %{
          src: "/images/icon-maskable-512.png",
          sizes: "512x512",
          type: "image/png",
          purpose: "maskable"
        }
      ]
    }
  end

  # robots.txt, llms.txt and the manifest answer every visitor with the same
  # bytes and carry nothing personal, so they are `public` cacheable like
  # /sitemap.xml and /.well-known/security.txt beside them in the router (an
  # hour, short enough
  # that flipping :ai_crawler_policy reaches crawlers promptly; Googlebot keeps
  # its own robots.txt copy for up to 24h regardless).
  #
  # This is NOT what makes them readable in Safari, though it was the first
  # suspect: the `nosniff` header is, and it comes from the :machine_docs
  # pipeline in the router, which explains the whole trap.
  defp discovery_cache_headers(conn) do
    put_resp_header(conn, "cache-control", "public, max-age=3600")
  end

  def impressum(conn, _params) do
    render_legal(conn, "impressum", gettext("About us"))
  end

  def datenschutzerklaerung(conn, _params) do
    render_legal(conn, "datenschutzerklaerung", gettext("Datenschutzerklärung"))
  end

  # The platform terms of use (AGB / Nutzungsbedingungen), incorporated into
  # the contract via the sign-up consent line.
  def nutzungsbedingungen(conn, _params) do
    render_legal(conn, "nutzungsbedingungen", gettext("Nutzungsbedingungen"))
  end

  # The legal pages are per-installation content (every operator states their
  # own identity), written by admins at /admin/legal as trusted Markdown and
  # stored in Vutuv.Legal. Legal copy itself is not translated; only the title
  # and the not-written-yet placeholder are.
  defp render_legal(conn, slug, title) do
    render(conn, "legal.html", page: Vutuv.Legal.get_page(slug), page_title: title)
  end

  @doc """
  The helper page for `/username`.

  "username" is a placeholder people copy verbatim out of instructions ("your
  profile lives at vutuv.de/username"), so rather than a bare 404 we explain
  that it stands for the person's real handle and link a concrete example.
  Served with a 404 status (there is no page or member literally called
  "username") through the shared `VutuvWeb.ErrorHTML` error card, the same way
  `Plug.AuthAdmin` renders its explanatory 403.
  """
  def username_placeholder(conn, _params) do
    conn
    |> put_status(:not_found)
    |> put_view(html: VutuvWeb.ErrorHTML)
    |> render("username_placeholder.html")
  end

  @doc """
  The rescue for `/{{username}}` — the unsubstituted newsletter merge tag.

  The July 2026 newsletter shipped its profile link with the `{{username}}`
  merge tag still literal inside the href (the Markdown autolinker had
  percent-encoded the braces, hiding the tag from the substitution), so
  thousands of inboxes hold a link to `/%7B%7Busername%7D%7D`. A logged-in
  member is forwarded to where that link was meant to point — their own
  profile; everyone else gets the same placeholder helper as `/username`.
  """
  def newsletter_username_placeholder(conn, params) do
    case conn.assigns[:current_user] do
      %User{} = user -> redirect(conn, to: ~p"/#{user}")
      _nil -> username_placeholder(conn, params)
    end
  end

  def new_registration(conn, %{"user" => user_params}) do
    user_params = expand_fediverse_choice(user_params)

    # Extract defensively: a malformed "emails" param (not the nested
    # %{"0" => %{"value" => …}} the form produces) must reach register_user/2
    # as a plain error changeset, not crash on chained Access indexing.
    email =
      case user_params do
        %{"emails" => %{"0" => %{"value" => value}}} -> value
        _ -> nil
      end

    case Vutuv.Accounts.register_user(conn, user_params) do
      {:ok, _user} ->
        # Credit the headline this visitor was shown. The variant stays in the
        # session, so the PIN that follows can be credited too.
        conn
        |> LandingExperiment.record_signup()
        |> handle_post_registration_login(email)

      {:error, changeset} ->
        if Vutuv.Accounts.email_already_taken?(changeset) do
          # Don't betray that the address exists: render the identical screen a
          # fresh sign-up gets, and let the owner's inbox carry the truth (a
          # "someone tried to register" notice with a login link). Surfacing the
          # "has already been taken" error here would be an enumeration oracle.
          handle_existing_email_registration(conn, email)
        else
          # The same landing page again, so the same headline: assign the
          # session's variant without counting a second view for it.
          conn
          |> LandingExperiment.assign_variant_without_view()
          |> put_status(:unprocessable_entity)
          |> render_landing(changeset: changeset)
        end
    end
  end

  # The sign-up form asks about the Fediverse once; `/settings/fediverse` has
  # three switches. Ticking the box means the whole thing, so it sets all three:
  # taking part, the reactions that come back, and the replies people write out
  # there. That is why the box's own text has to name the reply storage and its
  # six-month limit — a consent may only cover what it says out loud, and one of
  # these three keeps a stranger's words on our server.
  #
  # Unticking sets participation to false and leaves the other two alone, at
  # their schema defaults (reactions on, replies off). They mean nothing while
  # nobody federates, and if the member later switches participation on from
  # `/settings/fediverse` — where the switch promises no reply storage — they
  # land on exactly the defaults that page argues for, rather than on a silent
  # echo of a box they unticked at sign-up.
  defp expand_fediverse_choice(%{"fediverse_followers?" => value} = params)
       when value in [true, "true", "1", "on"] do
    Map.merge(params, %{"fediverse_reactions?" => "true", "fediverse_replies?" => "true"})
  end

  defp expand_fediverse_choice(params), do: params

  defp handle_post_registration_login(conn, email) do
    # The account was just created, so login_by_email/2 always mails the PIN
    # and advances to the confirmation screen.
    {:ok, conn} = Vutuv.Accounts.login_by_email(conn, email, :registration)
    ControllerHelpers.render_pin_screen(conn)
  end

  # Same confirmation screen as a real sign-up (so the response can't be told
  # apart), and no account is minted here. What reaches the address depends on
  # what is behind it — an established member gets a notice, an abandoned
  # sign-up gets a fresh PIN so a second attempt actually works; see
  # `Accounts.notify_registration_attempt/3`.
  #
  # The rate limit is checked for every address, not just the ones that would
  # get a PIN, so the bucket behaves identically whoever is typed in. It is the
  # same budget the login form spends, because it is the same kind of mail; a
  # spent budget falls back to the notice. (The notice itself is not throttled,
  # which is unchanged and predates this.)
  defp handle_existing_email_registration(conn, email) do
    pin_allowed? = RateLimit.check(conn, :login_email, email) == :ok

    {:ok, conn} = Vutuv.Accounts.notify_registration_attempt(conn, email, pin_allowed?)
    ControllerHelpers.render_pin_screen(conn)
  end

  # Also served as Markdown / text / JSON via VutuvWeb.AgentDocs.ListDocs.
  # Keep most_followed_users.html and the doc builder in sync
  # (agent_docs_drift_test.exs).
  def most_followed_users(conn, _params) do
    users = Vutuv.Social.most_followed_users(1000)
    work_info_by_id = VutuvWeb.UserHelpers.work_information_map(users, 60)
    tags_by_id = VutuvWeb.UserHelpers.tag_summary_map(users, 4)

    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "most_followed_users.html",
          page_title: gettext("Most Followed Users"),
          users: users,
          work_info_by_id: work_info_by_id,
          tags_by_id: tags_by_id,
          following_by_id: VutuvWeb.UserHelpers.following_map(conn.assigns[:current_user], users)
        )
      end,
      doc: fn -> ListDocs.build_most_followed(users, work_info_by_id, tags_by_id) end
    )
  end

  @llms_txt """
  # vutuv

  vutuv is a free social/business network. Every public page is also
  available in agent-friendly formats under the same URL plus an extension:

  - `<page>.md`   — Markdown with YAML frontmatter (or `Accept: text/markdown`)
  - `<page>.txt`  — plain text, 80 columns (or `Accept: text/plain`)
  - `<page>.json` — flat JSON document (or `Accept: application/json`)
  - `<page>.xml`  — flat XML document (or `Accept: application/xml`)

  Labels default to English; add `?lang=de` for a German rendering. The
  member-written content keeps its original language either way.

  Documents carry `schema_version` (currently #{AgentDocs.schema_version()};
  additions are non-breaking) and `generated_at`. Responses carry a
  `Content-Signal` header; respect it — members can opt out of search/AI use.
  A single opt-out is also embedded in the document body (`noindex` /
  `noai`). A member who opted out of BOTH serves no profile documents at
  all: their profile-namespace extension URLs answer 404 (the vCard stays).

  ## Pages

  - `/<username>` — member profile (also `/<username>.vcf` as vCard 3.0)
  - `/<username>/posts` — post archive, also `/<username>/posts/<year>[/<month>[/<day>]]`
  - `/<username>/posts/<id>` — a single post with replies
  - `/<username>/followers`, `/<username>/following`, `/<username>/connections` — people lists
  - `/<username>/<section>` — the profile sections in full: `work_experiences`,
    `educations`, `qualifications`, `languages`, `links`, `social_media_accounts`,
    `messengers`, `addresses`, `phone_numbers`, `emails` (public addresses only),
    `tags`, `job_references` (Arbeitszeugnisse the member chose to publish, with
    their full text); a single entry lives at `/<username>/<section>/<id-or-slug>`
  - `/<username>/tags/<tag>/endorsers` — everyone who endorses this member for that tag
  - `/tags/<tag>` — a tag and its most endorsed members
  - `/listings/most_followed_users` — the most followed members
  - `/system/members` — the member directory: everyone open to search engines,
    filed by last-name initial at `/system/members/<a-z|other>`
  - `/system/markdown` — what members may write in a post: the Markdown
    reference, also raw at `/system/markdown.md` (`?lang=de` for German)
  - `/system/mastodon` — how to reach this installation from a Mastodon-compatible
    app: the address to enter, what such an app can do here and what it cannot,
    also raw at `/system/mastodon.md` (`?lang=de` for German)
  - `/organizations` — the verified organization directory; one organization at `/organizations/<slug>`
  - `/organizations/<slug>/posts/<id>` — a post published in an organization's own
    name; the organization is the author, so there is no member behind it to look up
  - `/jobs` — the public job board: open positions, filterable, newest first
  - `/jobs/<slug>` — a job posting: role, location, pay range, tags and how to apply
  - `/system/media-kit` — press material: boilerplate in three lengths, logo files,
    colours, screenshots and the press contact (English only, whatever `?lang=` says)
  - `/system/investors` — who to contact about investing, and how many members,
    posts and Fediverse accounts this installation has (English only)
  {{ads}}

  List pages paginate with `?page=N`.

  ## Policies

  Plain HTML pages (German, no agent-format siblings):

  - `/nutzungsbedingungen` — terms of use (Nutzungsbedingungen / AGB)
  - `/datenschutzerklaerung` — privacy policy (Datenschutzerklärung)
  - `/impressum` — provider identification / legal notice (Impressum)
  - `/community` — community guidelines

  ## Discovery

  - `/sitemap.xml` — sitemap index (members, posts, tags, static pages)
  - `/<username>/posts/feed.xml` — a member's posts as RSS 2.0, full content
  - `/posts/feed.xml` — the latest public posts site-wide (RSS 2.0)
  - `/.well-known/agent-skills/index.json` — agent-skills discovery
    (Cloudflare draft); the skill teaches this whole surface
  - `/.well-known/security.txt` — vulnerability-report contact (RFC 9116)

  Responses carry `Link` headers (`describedby` -> this file, `sitemap`,
  per-page `alternate` siblings, `canonical` on the agent documents) and
  Accept-negotiated documents name their extension URL in
  `Content-Location`. Profiles embed schema.org JSON-LD (Person), post
  permalinks a BlogPosting.

  ## API

  An authenticated REST/JSON API for third-party apps and scripts lives at
  `/api/2.0` (Bearer tokens or OAuth 2, scoped permissions, 5,000
  requests/hour, signed webhooks). Documentation: `/developers` — also as
  raw Markdown at `/developers.md`, `/developers/authentication.md`,
  `/developers/cookbook.md` (task recipes: posting, direct messages, ...),
  `/developers/data-model.md` (entities and visibility rules),
  `/developers/reference.md`, `/developers/jobs.md` (job postings and
  organizations) and `/developers/webhooks.md`.

  vutuv is open source: {{source}} — bug reports
  and feature requests via GitHub issues.
  """

  @doc "Serves /llms.txt: the agent-format discovery file (llms.txt convention)."
  def llms(conn, _params) do
    conn
    |> discovery_cache_headers()
    |> put_resp_content_type("text/plain")
    |> send_resp(200, llms_txt())
  end

  # The document is a compile-time constant with one hole in it, because one of
  # the pages it lists is optional. `:ads_enabled` ships **off** (config.exs),
  # and the ad page 404s while it is — so listing `/ads` unconditionally pointed
  # every installation's agents at a dead URL, vutuv.de included. A discovery
  # file that names a page which is not there is worse than one that stays quiet
  # about a feature.
  # Both placeholders are substituted at REQUEST time, not interpolated into the
  # heredoc: `@llms_txt` is a module attribute, so `#{…}` in it would freeze the
  # value at compile time — before `config/runtime.exs` reads `SOURCE_URL`, which
  # is the whole point of the setting.
  defp llms_txt do
    @llms_txt
    |> String.replace("{{ads}}\n", ads_entry())
    |> String.replace("{{source}}", SourceRepo.url())
  end

  defp ads_entry do
    if Vutuv.Ads.enabled?() do
      "- `/ads` — the daily text ad: price, conditions, next available day\n" <>
        "  (booking happens online and requires a login)\n"
    else
      ""
    end
  end

  @doc """
  Serves the default link-preview image (`VutuvWeb.OgCard`) — the
  `og:image` of every page that has no better one. 404 on a host whose
  libvips cannot generate it (the pages then simply omit the tag).
  """
  def og_card(conn, _params) do
    case VutuvWeb.OgCard.png() do
      {:ok, png} ->
        conn
        # `nil` as the third argument drops Phoenix's default `; charset=utf-8`,
        # which is meaningless on a binary body and makes strict clients treat
        # the response as something other than a plain PNG. Every binary
        # response in the app passes it (binary_content_type_test.exs).
        |> put_resp_content_type("image/png", nil)
        |> put_resp_header("cache-control", "public, max-age=86400")
        |> send_resp(200, png)

      :error ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Not Found")
    end
  end

  # If a PIN is already in flight (the visitor entered their email, got a PIN,
  # then came back to "/"), show the PIN-entry form instead of the sign-up page
  # so they can finish. Which of the two PIN screens is decided by the flow the
  # cookie records: somebody half-way through a REGISTRATION used to land on the
  # login screen here, which told them to "log in with one of your other
  # addresses" — advice for an account they do not have yet (reported
  # 2026-08-04). The two screens differ only in copy, and both registration
  # branches mint the same cookie, so this leaks nothing about the address.
  defp display_pin_entry(conn, _params) do
    # A valid signed cookie means a login is in progress for that identity;
    # show the PIN form. Deliberately NOT gated on a PIN row existing in the
    # DB - that check would betray whether the entered address has an account
    # (an enumeration oracle), since at step 1 an unknown address sets the
    # same cookie but creates no PIN row.
    case Vutuv.Accounts.read_pin_cookie(conn) do
      nil -> conn
      _email -> conn |> ControllerHelpers.render_pin_screen() |> halt()
    end
  end
end
