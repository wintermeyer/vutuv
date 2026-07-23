defmodule VutuvWeb.WelcomeController do
  @moduledoc """
  The one-time welcome page (`/system/welcome`).

  A fresh account arrives with a name, three tags and an email — nothing that
  says *where* this person is or *whether they are looking*, the two facts the
  rest of the site needs to be useful to them (the `ort:` people search, the
  job board, a recruiter's saved search). Asking during sign-up would lengthen
  the form that stands between a visitor and an account, so we ask **once**,
  right after the registration PIN, on a page that is trivial to skip.

  Two groups, one form:

    * **Where are you?** — a Private/Work label, postal code, city, country.
      Validation is deliberately lax (`Address.welcome_changeset/2`): any one
      of the three is a complete answer and none of them is required. What is
      filled in becomes an ordinary profile address, so it shows on the profile
      and answers `ort:`/`city:` searches like every other address.
    * **Are you looking for a job?** — the availability status and, revealed
      only once a status is picked, the minimum salary expectation and the
      preferred workplace form. These are the existing issue #870 / #928 fields
      with their existing visibility defaults (status: signed-in members,
      salary: nobody), so nothing this page stores is more public than what the
      Basics form would store.

  **The URL is one-shot.** Two things must agree for the page to render: the
  account has never finished it (`users.welcome_completed_at` is NULL) *and*
  this session was routed here by the confirming PIN (the `:welcome_pending`
  session key, set by `VutuvWeb.SessionController`). So it opens once, survives
  a reload and a failed submit, and every later visit — a bookmark, a typed
  URL, another session — lands on the member's profile instead. A logged-out
  visitor never reaches the controller at all: the settings pipeline's
  RequireLogin sends them to the start page. Everything on the page stays
  editable under /settings, and nagging on every login is exactly what this
  page is designed not to do.
  """
  use VutuvWeb, :controller

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Profiles.Address
  alias VutuvWeb.Home

  plug(VutuvWeb.Plug.AuthUser)

  def show(conn, _params) do
    user = conn.assigns[:user]

    if open?(conn, user) do
      render_form(
        conn,
        user,
        Address.welcome_changeset(%Address{}, %{}),
        User.changeset(user, %{})
      )
    else
      redirect(conn, to: ~p"/#{user}")
    end
  end

  # One POST for both buttons. "Skip" carries no data, so it lands in the same
  # complete_welcome/2 with empty groups: the flag is stamped, nothing is saved.
  def create(conn, params) do
    user = conn.assigns[:user]

    cond do
      not open?(conn, user) -> redirect(conn, to: ~p"/#{user}")
      params["skip"] -> save(conn, user, %{})
      true -> save(conn, user, Map.take(params, ["address", "user"]))
    end
  end

  # Never finished, and this session was sent here by the confirming PIN.
  defp open?(conn, user) do
    Accounts.needs_welcome?(user) and get_session(conn, :welcome_pending) == true
  end

  defp save(conn, user, params) do
    case Accounts.complete_welcome(user, params) do
      {:ok, updated} ->
        # No toast: the member just answered two questions and lands on their
        # own profile, where the completion checklist already says what is
        # still missing. A greeting on top would be noise.
        conn
        # The one-shot key is spent: from here the URL redirects like any
        # other visit.
        |> delete_session(:welcome_pending)
        |> redirect(to: Home.path(updated))

      {:error, %{address: address_changeset, user: user_changeset}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_form(user, address_changeset, user_changeset)
    end
  end

  defp render_form(conn, user, address_changeset, user_changeset) do
    render(conn, "show.html",
      user: user,
      address_changeset: address_changeset,
      user_changeset: user_changeset,
      page_title: gettext("Welcome")
    )
  end
end
