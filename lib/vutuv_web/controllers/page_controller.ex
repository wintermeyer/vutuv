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
    user_counter = Repo.one(from(u in "users", select: count(u.id)))

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
  Disallow: /sessions
  Disallow: /api/
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

  def redirect_user(conn, %{"slug" => slug}) do
    conn
    |> put_status(301)
    |> redirect(to: ~p"/users/#{slug}")
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
        user_counter = Repo.one(from(u in "users", select: count(u.id)))

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
    users =
      Repo.all(
        from(u in User,
          left_join: f in assoc(u, :followers),
          group_by: u.id,
          order_by: [fragment("count(?) DESC", f.id), u.first_name, u.last_name],
          limit: 100
        )
      )

    render(conn, "most_followed_users.html", users: users)
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
    Vutuv.Repo.one(
      from(m in Vutuv.Accounts.LoginPin,
        join: u in assoc(m, :user),
        join: e in assoc(u, :emails),
        where: e.value == ^email and m.type == ^"login",
        select: m.created_at
      )
    )
    |> case do
      nil ->
        Vutuv.Accounts.delete_pin_cookie(conn)

      _ ->
        conn
        |> put_view(VutuvWeb.SessionHTML)
        |> render("pin_user_login.html", body_class: "stretch")
        |> halt
    end
  end
end
