defmodule VutuvWeb.PageController do
  use VutuvWeb, :controller
  plug(:display_pin_entry when action in [:index])
  plug(VutuvWeb.Plug.RequireUserLoggedOut when action in [:index])
  alias Vutuv.Accounts.Email
  alias Vutuv.Accounts.User
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.ListDocs

  def index(conn, _params) do
    changeset =
      User.changeset(%User{})
      |> Ecto.Changeset.put_assoc(:emails, [%Email{}])

    prefetch = "/listings/most_followed_users"

    # The member count is rendered by the embedded VutuvWeb.MemberCountLive (it
    # ticks up live), so the controller no longer fetches it here.
    render(conn, "index.html",
      changeset: changeset,
      prefetch: prefetch
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
    |> put_resp_content_type("text/plain")
    |> send_resp(200, VutuvWeb.RobotsTxt.render(VutuvWeb.ContentPolicy.policy()))
  end

  def impressum(conn, _params) do
    render(conn, "impressum.html")
  end

  def datenschutzerklaerung(conn, _params) do
    render(conn, "datenschutzerklaerung.html")
  end

  def new_registration(conn, %{"user" => user_params}) do
    email = user_params["emails"]["0"]["value"]

    case Vutuv.Accounts.register_user(conn, user_params) do
      {:ok, _user} ->
        handle_post_registration_login(conn, email)

      {:error, changeset} ->
        if Vutuv.Accounts.email_already_taken?(changeset) do
          # Don't betray that the address exists: render the identical screen a
          # fresh sign-up gets, and let the owner's inbox carry the truth (a
          # "someone tried to register" notice with a login link). Surfacing the
          # "has already been taken" error here would be an enumeration oracle.
          handle_existing_email_registration(conn, email)
        else
          conn |> put_status(:unprocessable_entity) |> render("index.html", changeset: changeset)
        end
    end
  end

  defp handle_post_registration_login(conn, email) do
    # The account was just created, so login_by_email/2 always mails the PIN
    # and advances to the confirmation screen.
    {:ok, conn} = Vutuv.Accounts.login_by_email(conn, email)
    render(conn, "pin_new_registration.html")
  end

  # Same confirmation screen as a real sign-up (so the response can't be told
  # apart), but notify_registration_attempt/2 mints no account and sends the
  # existing owner a notice instead of a PIN.
  defp handle_existing_email_registration(conn, email) do
    {:ok, conn} = Vutuv.Accounts.notify_registration_attempt(conn, email)
    render(conn, "pin_new_registration.html")
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

  ## Pages

  - `/<username>` — member profile (also `/<username>.vcf` as vCard 3.0)
  - `/<username>/posts` — post archive, also `/<username>/posts/<year>[/<month>[/<day>]]`
  - `/<username>/posts/<id>` — a single post with replies
  - `/<username>/followers`, `/<username>/following`, `/<username>/connections` — people lists
  - `/<username>/<section>` — the profile sections in full: `work_experiences`,
    `links`, `social_media_accounts`, `addresses`, `phone_numbers`, `emails`
    (public addresses only), `tags`; a single entry lives at
    `/<username>/<section>/<id-or-slug>`
  - `/<username>/tags/<tag>/endorsers` — everyone who endorses this member for that tag
  - `/tags/<tag>` — a tag and its most endorsed members
  - `/listings/most_followed_users` — the most followed members
  - `/ads` — the daily text ad: price, conditions, next available day
    (booking happens online and requires a login)

  List pages paginate with `?page=N`.

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
  `/developers/reference.md` and `/developers/webhooks.md`.

  vutuv is open source: https://github.com/wintermeyer/vutuv — bug reports
  and feature requests via GitHub issues.
  """

  @doc "Serves /llms.txt: the agent-format discovery file (llms.txt convention)."
  def llms(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, @llms_txt)
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
        |> put_resp_content_type("image/png")
        |> put_resp_header("cache-control", "public, max-age=86400")
        |> send_resp(200, png)

      :error ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Not Found")
    end
  end

  # If a login PIN is already in flight (the visitor entered their email, got a
  # PIN, then came back to "/"), show the PIN-entry form instead of the sign-up
  # page so they can finish logging in.
  defp display_pin_entry(conn, _params) do
    # A valid signed cookie means a login is in progress for that identity;
    # show the PIN form. Deliberately NOT gated on a PIN row existing in the
    # DB - that check would betray whether the entered address has an account
    # (an enumeration oracle), since at step 1 an unknown address sets the
    # same cookie but creates no PIN row.
    case Vutuv.Accounts.read_pin_cookie(conn) do
      nil ->
        conn

      _email ->
        conn
        |> put_view(VutuvWeb.SessionHTML)
        |> render("pin_user_login.html")
        |> halt()
    end
  end
end
