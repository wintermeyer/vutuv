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

  @robots_txt """
  # robots.txt for vutuv.de
  #
  # vutuv is the friendly social/business network.
  # Humans and robots are welcome and overly enthusiastic crawlers
  # are politely asked to read the house rules.

  User-agent: *

  # Help yourself to the public stuff: profiles, tags, listings.
  Allow: /

  # ...but these are backstage. No autographs, no peeking.
  Disallow: /admin/
  Disallow: /login
  Disallow: /logout
  Disallow: /sessions
  Disallow: /api/

  # Search results are an endless hall of mirrors; don't get lost in there.
  Disallow: /search

  # The old /users/... URLs are permanent redirects now; skip the detour.
  Disallow: /users/

  # Personal profile detail pages (phone numbers, emails, addresses, links,
  # social media, work history, followers, ...) are off-limits. The profile
  # page /<slug> itself stays crawlable; only its sub-pages are blocked.
  Disallow: /*/addresses
  Disallow: /*/connections
  Disallow: /*/edit
  Disallow: /*/emails
  Disallow: /*/followers
  Disallow: /*/following
  Disallow: /*/groups
  Disallow: /*/links
  Disallow: /*/phone_numbers
  Disallow: /*/search_terms
  Disallow: /*/slugs
  Disallow: /*/social_media_accounts
  Disallow: /*/tags
  Disallow: /*/work_experiences
  """

  @doc """
  Serves robots.txt from the application rather than a static file.

  `priv/static` is gitignored in this project, so a code route keeps the
  policy under version control and lets us tune it per environment later
  (for example, a blanket `Disallow: /` on a staging host).
  """
  def robots(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, @robots_txt)
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
        render(conn, "index.html", changeset: changeset)
    end
  end

  defp handle_post_registration_login(conn, email) do
    case Vutuv.Accounts.login_by_email(conn, email) do
      {:ok, conn} ->
        render(conn, "pin_new_registration.html")

      # The account exists but the PIN mail could not be started (e.g. rate
      # limited). Never bounce them to "/" without a word — say what happened
      # and where to continue.
      {:error, _reason, conn} ->
        conn
        |> put_flash(
          :error,
          gettext(
            "Your account was created, but we could not send the sign-in PIN right now. Please sign in with your email address to try again."
          )
        )
        |> redirect(to: ~p"/login")
    end
  end

  # Also served as Markdown / text / JSON via VutuvWeb.AgentDocs.ListDocs.
  # Keep most_followed_users.html and the doc builder in sync
  # (agent_docs_drift_test.exs).
  def most_followed_users(conn, _params) do
    users = Vutuv.Social.most_followed_users(100)
    work_info_by_id = VutuvWeb.UserHelpers.work_information_map(users, 60)

    AgentDocs.respond(conn,
      html: fn conn ->
        render(conn, "most_followed_users.html",
          users: users,
          work_info_by_id: work_info_by_id,
          following_by_id: VutuvWeb.UserHelpers.following_map(conn.assigns[:current_user], users)
        )
      end,
      doc: fn -> ListDocs.build_most_followed(users, work_info_by_id) end
    )
  end

  @llms_txt """
  # vutuv

  vutuv is a free social/business network. Every public page is also
  available in agent-friendly formats under the same URL plus an extension:

  - `<page>.md`   — Markdown with YAML frontmatter (or `Accept: text/markdown`)
  - `<page>.txt`  — plain text, 80 columns (or `Accept: text/plain`)
  - `<page>.json` — flat JSON document (or `Accept: application/json`)

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
  - `/tags/<tag>` — a skill tag and its most endorsed members
  - `/listings/most_followed_users` — the most followed members

  List pages paginate with `?page=N`.
  """

  @doc "Serves /llms.txt: the agent-format discovery file (llms.txt convention)."
  def llms(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, @llms_txt)
  end

  # If a login PIN is already in flight (the visitor entered their email, got a
  # PIN, then came back to "/"), show the PIN-entry form instead of the sign-up
  # page so they can finish logging in.
  defp display_pin_entry(conn, _params) do
    case Vutuv.Accounts.read_pin_cookie(conn) do
      nil -> conn
      email -> check_pin_session(conn, email)
    end
  end

  defp check_pin_session(conn, email) do
    if Vutuv.Accounts.login_pin_pending?(email) do
      conn
      |> put_view(VutuvWeb.SessionHTML)
      |> render("pin_user_login.html")
      |> halt
    else
      Vutuv.Accounts.delete_pin_cookie(conn)
    end
  end
end
