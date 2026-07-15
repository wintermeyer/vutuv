defmodule VutuvWeb.Admin.UserDetailLive do
  @moduledoc """
  The admin member detail page (`/admin/users/:id`, issue #934). The member
  browser (`VutuvWeb.Admin.UserLive`) links each row here instead of straight to
  the public profile, so an admin investigating a member lands on one screen
  that carries their account status plus their **jobs footprint** — the live and
  total postings, the open job-related moderation cases, and the cold-outreach
  counter admins lean on when a recruiter's messaging is questioned (the same
  footprint `Vutuv.Jobs.member_job_footprint/1` builds for the `/admin/jobs`
  drawer). From here it is one click to the member's preference overrides, their
  postings on the jobs board, and their public profile.

  Read-only; it lives in the `:admin` live_session (`on_mount :require_admin`)
  so the dead `:admin` pipeline 403s the disconnected render and the on_mount
  guards the socket. A missing or malformed id redirects back to the browser
  rather than 500ing.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.Admin.MemberBadges, only: [status_badges: 1, badge_class: 1]
  import VutuvWeb.UserHelpers, only: [member_name: 1]

  alias Vutuv.Accounts
  alias Vutuv.Chat
  alias Vutuv.Jobs

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case fetch_member(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("This member no longer exists."))
         |> redirect(to: ~p"/admin/users")}

      user ->
        {:ok,
         socket
         |> assign(:page_title, member_name(user))
         |> assign(:user, user)
         |> assign(:footprint, Jobs.member_job_footprint(user))
         |> assign(:cold_limit, Chat.new_conversation_limit())}
    end
  end

  # Cast the UUID before hitting the DB so a malformed :id is a clean 404-style
  # redirect, not an Ecto.Query.CastError 500 (the sibling preferences page
  # guards the same way).
  defp fetch_member(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _uuid} -> Accounts.get_user(id)
      :error -> nil
    end
  end

  # Standard secondary-button recipe (design.md); reused by the footer links.
  defp button_class,
    do:
      "rounded-lg bg-slate-100 px-3 py-1.5 text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title={member_name(@user)}
      crumbs={[
        {gettext("Admin"), ~p"/admin"},
        {gettext("Members"), ~p"/admin/users"},
        member_name(@user)
      ]}
    />

    <div class="card-list">
      <section class="card" id="user-detail">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div class="flex min-w-0 items-center gap-3">
            <.avatar user={@user} size="md" />
            <div class="min-w-0">
              <h1 class="breakwrap">{member_name(@user)}</h1>
              <.link
                id="member-profile-link"
                navigate={~p"/#{@user}"}
                class="text-sm font-semibold text-brand-600 hover:text-brand-700"
              >
                @{@user.username}
              </.link>
            </div>
          </div>

          <div class="flex flex-wrap gap-1">
            <span class={[
              "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-semibold",
              if(@user.email_confirmed?,
                do: "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/40 dark:text-emerald-200",
                else: "bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-300"
              )
            ]}>
              {if @user.email_confirmed?, do: gettext("PIN"), else: gettext("Unconfirmed")}
            </span>
            <span
              :for={{label, tone} <- status_badges(@user)}
              class={[
                "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-semibold",
                badge_class(tone)
              ]}
            >
              {label}
            </span>
          </div>
        </div>

        <dl class="mt-4">
          <dt class="card__label">{gettext("Joined")}</dt>
          <dd class="mt-1 text-sm text-slate-700 dark:text-slate-300">
            <.local_time at={@user.inserted_at} id="member-joined" format="%Y-%m-%d" />
          </dd>
        </dl>

        <%!-- The member's jobs footprint (issue #934): what an admin looking into a
        spammy recruiter reaches for. Mirrors the /admin/jobs poster drawer. --%>
        <div
          id="jobs-footprint"
          class="mt-5 rounded-xl bg-slate-50 p-4 ring-1 ring-slate-200 dark:bg-slate-800/50 dark:ring-slate-700"
        >
          <p class="card__label">{gettext("Jobs footprint")}</p>
          <dl class="mt-2 grid grid-cols-2 gap-x-4 gap-y-2 text-sm sm:grid-cols-4">
            <div>
              <dt class="text-xs text-slate-500">{gettext("Live postings")}</dt>
              <dd id="footprint-active" class="font-semibold tabular-nums">
                {delimited_count(@footprint.active)}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-slate-500">{gettext("Total postings")}</dt>
              <dd id="footprint-total" class="font-semibold tabular-nums">
                {delimited_count(@footprint.total)}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-slate-500">{gettext("Open job cases")}</dt>
              <dd id="footprint-cases" class="font-semibold tabular-nums">
                {delimited_count(@footprint.open_cases)}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-slate-500">{gettext("Cold outreach")}</dt>
              <dd
                id="footprint-cold"
                class={[
                  "font-semibold tabular-nums",
                  @footprint.cold_outreach >= @cold_limit && "text-amber-700 dark:text-amber-300"
                ]}
              >
                {delimited_count(@footprint.cold_outreach)} / {delimited_count(@cold_limit)}
              </dd>
            </div>
          </dl>
        </div>

        <div class="mt-5 flex flex-wrap gap-2 border-t border-slate-100 pt-4 dark:border-slate-800">
          <.link
            id="member-prefs-link"
            navigate={~p"/admin/users/#{@user.id}/preferences"}
            class={button_class()}
          >
            {gettext("Preferences")}
          </.link>
          <.link
            :if={@user.username}
            id="member-postings-link"
            navigate={~p"/admin/jobs?#{[q: @user.username]}"}
            class={button_class()}
          >
            {gettext("Job postings")}
          </.link>
        </div>
      </section>
    </div>
    """
  end
end
