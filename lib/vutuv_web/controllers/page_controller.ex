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
  Disallow: /magic/
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
        template =
          case conn.cookies["_vutuv_fbs_temp"] do
            nil -> "new_registration.html"
            _ -> "pin_new_registration.html"
          end

        render(conn, template, body_class: "stretch")

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

  defp display_pin_entry(conn, _params) do
    case conn.cookies["_vutuv_fbs_temp"] do
      nil -> conn
      _ -> check_pin_session(conn)
    end
  end

  defp check_pin_session(conn) do
    Vutuv.Repo.one(
      from(m in Vutuv.Accounts.MagicLink,
        left_join: u in assoc(m, :user),
        left_join: e in assoc(u, :emails),
        where: e.value == ^unform_pin_cookie(conn) and m.magic_link_type == ^"login",
        select: m.magic_link_created_at
      )
    )
    |> case do
      nil ->
        delete_resp_cookie(conn, "_vutuv_fbs_temp", max_age: 1800)

      _ ->
        conn
        |> put_view(VutuvWeb.SessionHTML)
        |> render("pin_user_login.html", body_class: "stretch")
        |> halt
    end
  end

  defp unform_pin_cookie(%{cookies: %{"_vutuv_fbs_temp" => payload}} = conn) do
    salt = Application.fetch_env!(:vutuv, VutuvWeb.Endpoint)[:secret_key_base]

    Phoenix.Token.verify(conn, salt, payload)
    |> case do
      {:ok, email} -> email
      _ -> ""
    end
  end
end
