defmodule VutuvWeb.PageController do
  use VutuvWeb, :controller
  plug(:display_pin_entry when action in [:index])
  plug(VutuvWeb.Plug.RequireUserLoggedOut when action in [:index])
  alias Vutuv.Accounts.Email
  alias Vutuv.Accounts.User

  def index(conn, _params) do
    changeset =
      User.changeset(%User{})
      |> Ecto.Changeset.put_assoc(:emails, [%Email{}])

    prefetch = "/listings/most_followed_users"
    user_counter = Vutuv.Accounts.count_users()

    render(conn, "index.html",
      changeset: changeset,
      user_counter: user_counter,
      body_class: "stretch",
      prefetch: prefetch
    )
  end

  def redirect_index(conn, _params) do
    redirect(conn, to: ~p"/")
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
    render(conn, "impressum.html", conn: conn, body_class: "stretch")
  end

  def datenschutzerklaerung(conn, _params) do
    render(conn, "datenschutzerklaerung.html", conn: conn, body_class: "stretch")
  end

  def new_registration(conn, %{"user" => user_params}) do
    email = user_params["emails"]["0"]["value"]

    case Vutuv.Accounts.register_user(conn, user_params) do
      {:ok, _user} ->
        handle_post_registration_login(conn, email)

      {:error, changeset} ->
        user_counter = Vutuv.Accounts.count_users()

        render(conn, "index.html",
          changeset: changeset,
          user_counter: user_counter,
          body_class: "stretch"
        )
    end
  end

  defp handle_post_registration_login(conn, email) do
    case Vutuv.Accounts.login_by_email(conn, email) do
      {:ok, conn} ->
        render(conn, "pin_new_registration.html", body_class: "stretch")

      {:error, _reason, conn} ->
        redirect(conn, to: ~p"/")
    end
  end

  def most_followed_users(conn, _params) do
    users = Vutuv.Social.most_followed_users(100)

    render(conn, "most_followed_users.html",
      users: users,
      work_info_by_id: VutuvWeb.UserHelpers.work_information_map(users, 60),
      following_by_id: VutuvWeb.UserHelpers.following_map(conn.assigns[:current_user], users)
    )
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
      |> render("pin_user_login.html", body_class: "stretch")
      |> halt
    else
      Vutuv.Accounts.delete_pin_cookie(conn)
    end
  end
end
