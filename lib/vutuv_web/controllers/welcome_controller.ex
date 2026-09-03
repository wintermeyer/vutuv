defmodule VutuvWeb.WelcomeController do
  @moduledoc """
  The one-time welcome questions: where you are, whether you are looking, and
  who to follow.

  `/system/welcome` is where they are **answered** (the POST) and, as a page,
  where a rejected submit lands. Where a new member **meets** them is the modal
  the layout floats over their own profile right after the registration PIN
  (`VutuvWeb.Plug.WelcomeModal`, `VutuvWeb.WelcomeComponents.welcome_modal/1`),
  so the site is visibly already theirs and the questions read as an offer they
  can close.

  A fresh account arrives with a name, three tags and an email — nothing that
  says *where* this person is, nothing that says *whether they are looking*,
  and nothing at all in their feed. Asking during sign-up would lengthen the
  form that stands between a visitor and an account, so we ask **once**, right
  after the registration PIN, in a window that is trivial to close.

  **One step per screen, and the window only goes forward.** Each Weiter posts
  here, saves that step's group on its own (`Accounts.save_welcome_location/2`,
  `Accounts.save_welcome_job/2`, `Vutuv.Welcome.follow_suggested/2`), advances
  the `:welcome_step` session key and sends the member back to the page they
  were reading — so an address that has been typed is stored whatever becomes
  of the rest, and there is no Back button to make that ambiguous.
  `Vutuv.Welcome` owns the step list: the two questions, plus the suggested
  accounts wherever the locale has any (German today).

  Closing at any point — the ✕, "Skip for now", Esc, the backdrop — stamps
  `welcome_completed_at` and keeps whatever the earlier steps already saved.

  **It is one-shot.** Two things must agree, here and in the plug alike: the
  account has never finished it (`users.welcome_completed_at` is NULL) *and*
  this session was sent here by the confirming PIN (the `:welcome_pending`
  session key, set by `VutuvWeb.SessionController`). So the questions open
  once, survive a reload and a failed submit, and every later visit — a
  bookmark, a typed URL, another session — lands on the member's profile
  instead. A logged-out visitor never reaches the controller at all: the
  settings pipeline's RequireLogin sends them to the start page. Everything
  asked here stays editable under /settings, and nagging on every login is
  exactly what this is designed not to do.
  """
  use VutuvWeb, :controller

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Profiles.Address
  alias Vutuv.Welcome
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.Gettext, as: WebGettext
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

  # One POST for every button on every step. "Skip" and the ✕ carry no data and
  # land in finish/3; anything else saves the step the SESSION says we are on,
  # never the step the form claims, which is only the client's word for it.
  def create(conn, params) do
    user = conn.assigns[:user]

    cond do
      not open?(conn, user) -> redirect(conn, to: ~p"/#{user}")
      params["skip"] -> finish(conn, user, params)
      true -> advance(conn, user, params)
    end
  end

  # Never finished, and this session was sent here by the confirming PIN.
  defp open?(conn, user) do
    Accounts.needs_welcome?(user) and get_session(conn, :welcome_pending) == true
  end

  defp advance(conn, user, params) do
    steps = Welcome.steps(user, locale())
    step = Welcome.current_step(steps, get_session(conn, :welcome_step))

    case save(user, step, params) do
      {:ok, updated} ->
        case Welcome.next_step(steps, step) do
          :done -> finish(conn, updated, params)
          next -> conn |> put_session(:welcome_step, next) |> back_to(updated, params)
        end

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_step_error(user, step, changeset)
    end
  end

  defp save(user, :location, params), do: Accounts.save_welcome_location(user, params["address"])
  defp save(user, :job, params), do: Accounts.save_welcome_job(user, params["user"])

  defp save(user, :accounts, params) do
    Welcome.follow_suggested(user, List.wrap(params["follow"]))
    {:ok, user}
  end

  defp finish(conn, user, params) do
    case Accounts.complete_welcome(user) do
      {:ok, updated} ->
        # No toast: the member just answered a couple of questions and lands
        # back on the page they were reading, where the profile's completion
        # checklist already says what is still missing. A greeting on top of
        # that would be noise.
        conn
        # The one-shot keys are spent: from here the URL redirects like any
        # other visit and the modal is gone.
        |> delete_session(:welcome_pending)
        |> delete_session(:welcome_step)
        |> back_to(updated, params)

      {:error, _changeset} ->
        redirect(conn, to: Home.path(user))
    end
  end

  # Back to the page the window was floating over, so answering a step does not
  # also navigate. Only a local path is ever followed: the value is the form's
  # own hidden field, but it reaches us through the client either way.
  defp back_to(conn, user, params) do
    redirect(conn, to: ControllerHelpers.safe_return_to(params["return_to"]) || Home.path(user))
  end

  # A rejected step re-renders as a page, because a POST cannot re-open a modal
  # over a page it does not render. Rare — the fields are lax and capped in the
  # markup — and it is the same form, so the member sees what they typed with
  # the one bad field marked.
  defp render_step_error(conn, user, :location, changeset),
    do: render_form(conn, user, changeset, User.changeset(user, %{}))

  defp render_step_error(conn, user, _job, changeset),
    do: render_form(conn, user, Address.welcome_changeset(%Address{}, %{}), changeset)

  defp render_form(conn, user, address_changeset, user_changeset) do
    window = Welcome.window(user, locale())

    render(conn, "show.html",
      user: user,
      address_changeset: address_changeset,
      user_changeset: user_changeset,
      steps: window.steps,
      step: Welcome.current_step(window.steps, get_session(conn, :welcome_step)),
      suggestions: window.suggestions,
      return_to: nil,
      page_title: gettext("Welcome")
    )
  end

  defp locale, do: Gettext.get_locale(WebGettext)
end
