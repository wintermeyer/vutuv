defmodule VutuvWeb.Admin.JobLive do
  @moduledoc """
  The admin oversight dashboard for job postings (`/admin/jobs`, issue #934).
  Overview tiles (published / expiring within 7 days / frozen / open cases), a
  searchable (title / poster / organization), status-filtered, "has open
  report"-filtered, paginated list, and a per-posting detail drawer showing the
  poster, the organization attribution, timestamps, the view/apply counters,
  the report history and the poster's jobs footprint (including the
  cold-outreach counter). Actions — freeze / unfreeze / close / delete — act
  reload-free (a `push_patch` re-runs the single `handle_params` loader) and a
  freeze/unfreeze pings the public board so it re-queries with no reload.
  Filter/status/report/page/selection live in the URL, so a view is shareable.
  Lives in the `:admin` live_session, sharing the scaffold of
  `VutuvWeb.Admin.OrganizationLive`.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.Admin.ModerationHTML, only: [status_badge: 1]
  import VutuvWeb.UserHelpers, only: [member_name: 1]

  alias Vutuv.Jobs
  alias Vutuv.Jobs.JobPosting
  alias Vutuv.Pages

  @statuses ~w(all published expiring frozen closed expired draft)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, gettext("Job postings"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    status = if params["status"] in @statuses, do: params["status"], else: "all"
    report = if params["report"] == "open", do: "open", else: nil
    q = blank_to_nil(params["q"])
    page = Pages.page_param(params)

    result =
      Jobs.admin_jobs_page(
        status: if(status == "all", do: nil, else: status),
        report: report,
        search: q,
        page: page
      )

    detail = params["selected"] && Jobs.admin_job_detail(params["selected"])

    {:noreply,
     socket
     |> assign(:counts, Jobs.admin_overview_counts())
     |> assign(:status, status)
     |> assign(:report, report)
     |> assign(:q, q)
     |> assign(:result, result)
     |> assign(:selected_id, params["selected"])
     |> assign(:detail, detail)}
  end

  # ── events: filter/status/report/select rewrite the URL; handle_params reloads ──

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, push_patch(socket, to: patch_to(socket, %{"q" => params["q"], "selected" => nil}))}
  end

  def handle_event("status", %{"status" => status}, socket) do
    {:noreply,
     push_patch(socket,
       to: patch_to(socket, %{"status" => status, "selected" => nil, "page" => nil})
     )}
  end

  def handle_event("toggle-report", _params, socket) do
    report = if socket.assigns.report == "open", do: nil, else: "open"

    {:noreply,
     push_patch(socket,
       to: patch_to(socket, %{"report" => report, "selected" => nil, "page" => nil})
     )}
  end

  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: patch_to(socket, %{"selected" => id}))}
  end

  def handle_event("close-drawer", _params, socket) do
    {:noreply, push_patch(socket, to: patch_to(socket, %{"selected" => nil}))}
  end

  def handle_event("page", %{"page" => page}, socket) do
    {:noreply, push_patch(socket, to: patch_to(socket, %{"page" => to_string(page)}))}
  end

  # ── events: the moderation/lifecycle actions ──

  def handle_event("freeze", %{"id" => id}, socket),
    do: act(socket, id, &Jobs.admin_set_frozen(&1, true), gettext("Posting frozen."))

  def handle_event("unfreeze", %{"id" => id}, socket),
    do: act(socket, id, &Jobs.admin_set_frozen(&1, false), gettext("Posting unfrozen."))

  def handle_event("close-posting", %{"id" => id}, socket),
    do: act(socket, id, &Jobs.admin_close/1, gettext("Posting closed."))

  def handle_event("delete", %{"id" => id}, socket) do
    case Jobs.get_job_posting(id) do
      nil ->
        {:noreply, socket}

      posting ->
        {:ok, _} = Jobs.delete_job_posting(posting)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Posting deleted."))
         |> push_patch(to: patch_to(socket, %{"selected" => nil}))}
    end
  end

  # Keep the drawer open on freeze/unfreeze/close so the admin sees the new
  # status without re-selecting the row.
  defp act(socket, id, fun, message) do
    case Jobs.get_job_posting(id) do
      nil ->
        {:noreply, socket}

      posting ->
        {:ok, _} = fun.(posting)
        {:noreply, socket |> put_flash(:info, message) |> push_patch(to: patch_to(socket, %{}))}
    end
  end

  # ── URL helpers ──

  # The current URL with `overrides` merged; blanks/defaults dropped.
  defp patch_to(socket, overrides) do
    query =
      %{
        "q" => socket.assigns.q,
        "status" => socket.assigns.status,
        "report" => socket.assigns.report,
        "selected" => socket.assigns.selected_id
      }
      |> Map.merge(overrides)
      |> Enum.reject(fn {key, value} ->
        value in [nil, ""] or (key == "status" and value == "all")
      end)
      |> Map.new()

    if query == %{}, do: ~p"/admin/jobs", else: ~p"/admin/jobs?#{query}"
  end

  defp blank_to_nil(value) do
    case value && String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # ── status / labels ──

  defp status_chips, do: @statuses

  defp status_label("all"), do: gettext("All")
  defp status_label("published"), do: gettext("Live")
  defp status_label("expiring"), do: gettext("Expiring")
  defp status_label("frozen"), do: gettext("Frozen")
  defp status_label("closed"), do: gettext("Closed")
  defp status_label("expired"), do: gettext("Expired")
  defp status_label("draft"), do: gettext("Draft")

  # The badge for a posting in the list/drawer: frozen wins, else its calendar-
  # accurate effective status.
  defp posting_status_badge(%JobPosting{frozen_at: frozen}) when not is_nil(frozen),
    do:
      {gettext("Frozen"), "bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-200"}

  defp posting_status_badge(%JobPosting{} = posting) do
    case Jobs.effective_status(posting) do
      :published ->
        {gettext("Live"),
         "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/40 dark:text-emerald-200"}

      :expired ->
        {gettext("Expired"), "bg-slate-100 text-slate-500 dark:bg-slate-800 dark:text-slate-400"}

      :closed ->
        {gettext("Closed"), "bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-300"}

      :draft ->
        {gettext("Draft"), "bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-300"}
    end
  end

  defp employer(%JobPosting{organization: %{name: name}}), do: name
  defp employer(%JobPosting{hiring_org_name: name}) when is_binary(name) and name != "", do: name
  defp employer(_), do: gettext("(no employer)")

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title={gettext("Job postings")}
      crumbs={[{gettext("Admin"), ~p"/admin"}, gettext("Job postings")]}
    />

    <div class="mb-6 grid grid-cols-2 gap-3 sm:grid-cols-4">
      <.admin_stat_tile label={gettext("Live")} value={@counts.published} />
      <.admin_stat_tile label={gettext("Expiring (7 days)")} value={@counts.expiring} />
      <.admin_stat_tile label={gettext("Frozen")} value={@counts.frozen} />
      <.admin_stat_tile label={gettext("Open cases")} value={@counts.open_cases} attention={@counts.open_cases > 0} />
    </div>

    <div class="card-list">
      <section class="card">
        <div class="flex flex-wrap items-center gap-2">
          <button
            :for={chip <- status_chips()}
            type="button"
            phx-click="status"
            phx-value-status={chip}
            class={[
              "rounded-full px-3 py-1 text-sm font-semibold",
              if(@status == chip,
                do: "bg-brand-600 text-white",
                else: "bg-slate-100 text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
              )
            ]}
          >
            {status_label(chip)}
          </button>

          <span class="mx-1 h-5 w-px bg-slate-200 dark:bg-slate-700" aria-hidden="true"></span>

          <button
            type="button"
            phx-click="toggle-report"
            id="filter-reported"
            class={[
              "rounded-full px-3 py-1 text-sm font-semibold",
              if(@report == "open",
                do: "bg-amber-500 text-white",
                else: "bg-slate-100 text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
              )
            ]}
          >
            ⚑ {gettext("Open reports")}
          </button>
        </div>

        <form id="job-filter" phx-change="filter" phx-submit="filter" class="mt-4">
          <input
            type="search"
            name="q"
            value={@q}
            phx-debounce="250"
            autocomplete="off"
            placeholder={gettext("Search title, poster or organization")}
            class={input_class()}
          />
        </form>

        <p :if={@result.entries == []} class="card__empty">{gettext("No job postings match.")}</p>

        <div :if={@result.entries != []} class="mt-4 card__tablewrap">
          <table class="pure-table">
            <thead>
              <tr>
                <th>{gettext("Title")}</th>
                <th>{gettext("Poster")}</th>
                <th>{gettext("Status")}</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={posting <- @result.entries} id={"job-row-#{posting.id}"}>
                <td class="breakwrap font-medium">
                  {posting.title}
                  <span class="block text-xs text-slate-600 dark:text-slate-400">{employer(posting)}</span>
                </td>
                <td class="breakwrap text-slate-600 dark:text-slate-400">
                  <span :if={posting.user}>@{posting.user.username}</span>
                </td>
                <td>
                  <% {label, tone} = posting_status_badge(posting) %>
                  <span class={["inline-flex items-center rounded-full px-2 py-0.5 text-xs font-semibold", tone]}>{label}</span>
                </td>
                <td class="text-right">
                  <button
                    type="button"
                    phx-click="select"
                    phx-value-id={posting.id}
                    class="text-sm font-semibold text-brand-600 hover:text-brand-700"
                  >
                    {gettext("Details")} ›
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <.admin_pager page={@result.page} pages={@result.total_pages} />
      </section>

      {detail_card(assigns)}
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :integer, required: true)
  attr(:attention, :boolean, default: false)

  defp detail_card(%{detail: nil} = assigns), do: ~H""

  defp detail_card(assigns) do
    ~H"""
    <section class="card" id="job-detail">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <h2 class="text-lg font-bold text-slate-900 dark:text-slate-100">{@detail.posting.title}</h2>
          <p class="text-sm text-slate-600 dark:text-slate-400">
            <.link navigate={~p"/jobs/#{@detail.posting.slug}"} class="text-brand-600 hover:text-brand-700">
              /jobs/{@detail.posting.slug}
            </.link>
          </p>
        </div>
        <button type="button" phx-click="close-drawer" class="shrink-0 text-sm font-semibold text-slate-500 hover:text-slate-700 dark:hover:text-slate-300">
          {gettext("Close")}
        </button>
      </div>

      <dl class="mt-4 grid gap-4 sm:grid-cols-2">
        <div>
          <dt class="card__label">{gettext("Poster")}</dt>
          <dd class="mt-1 text-sm text-slate-700 dark:text-slate-300">
            <p :if={@detail.posting.user}>
              <.link navigate={~p"/#{@detail.posting.user.username}"} class="text-brand-600 hover:text-brand-700">
                @{@detail.posting.user.username}
              </.link>
              <span class="text-slate-500">{member_name(@detail.posting.user)}</span>
            </p>
            <p :if={is_nil(@detail.posting.user)} class="text-slate-500">{gettext("(deleted account)")}</p>
          </dd>
        </div>

        <div>
          <dt class="card__label">{gettext("Employer")}</dt>
          <dd class="mt-1 text-sm text-slate-700 dark:text-slate-300">
            <p :if={@detail.posting.organization}>
              <.link
                navigate={~p"/organizations/#{@detail.posting.organization.slug}"}
                class="text-brand-600 hover:text-brand-700"
              >
                {@detail.posting.organization.name}
              </.link>
              <span class="ml-1 text-xs font-semibold text-emerald-600 dark:text-emerald-300">
                ✓ {gettext("verified organization page")}
              </span>
            </p>
            <p :if={is_nil(@detail.posting.organization)}>
              {employer(@detail.posting)}
              <span class="ml-1 text-xs text-slate-500">{gettext("(free text, unverified)")}</span>
            </p>
          </dd>
        </div>

        <div>
          <dt class="card__label">{gettext("Status")}</dt>
          <dd class="mt-1 text-sm">
            <% {label, tone} = posting_status_badge(@detail.posting) %>
            <span class={["inline-flex items-center rounded-full px-2 py-0.5 text-xs font-semibold", tone]}>{label}</span>
          </dd>
        </div>

        <div>
          <dt class="card__label">{gettext("Counters")}</dt>
          <dd class="mt-1 text-sm text-slate-700 dark:text-slate-300">
            {gettext("%{views} views · %{clicks} apply clicks",
              views: delimited_count(@detail.posting.view_count),
              clicks: delimited_count(@detail.posting.apply_click_count)
            )}
          </dd>
        </div>

        <div>
          <dt class="card__label">{gettext("Published")}</dt>
          <dd class="mt-1 text-sm text-slate-700 dark:text-slate-300">
            <span :if={@detail.posting.first_published_at}>
              <.local_time at={@detail.posting.first_published_at} id="job-published" format="%Y-%m-%d" />
            </span>
            <span :if={is_nil(@detail.posting.first_published_at)} class="text-slate-500">{gettext("never")}</span>
          </dd>
        </div>

        <div>
          <dt class="card__label">{gettext("Expires")}</dt>
          <dd class="mt-1 text-sm text-slate-700 dark:text-slate-300">
            {(@detail.posting.expires_on && Calendar.strftime(@detail.posting.expires_on, "%Y-%m-%d")) || gettext("—")}
          </dd>
        </div>
      </dl>

      <%!-- The poster's jobs footprint, incl. the cold-outreach counter admins
      lean on when a recruiter's messaging is questioned. --%>
      <div :if={@detail.footprint} class="mt-5 rounded-xl bg-slate-50 p-4 ring-1 ring-slate-200 dark:bg-slate-800/50 dark:ring-slate-700">
        <p class="card__label">{gettext("Poster footprint")}</p>
        <dl class="mt-2 grid grid-cols-2 gap-x-4 gap-y-2 text-sm sm:grid-cols-4">
          <div>
            <dt class="text-xs text-slate-500">{gettext("Live postings")}</dt>
            <dd class="font-semibold tabular-nums">{delimited_count(@detail.footprint.active)}</dd>
          </div>
          <div>
            <dt class="text-xs text-slate-500">{gettext("Total postings")}</dt>
            <dd class="font-semibold tabular-nums">{delimited_count(@detail.footprint.total)}</dd>
          </div>
          <div>
            <dt class="text-xs text-slate-500">{gettext("Open job cases")}</dt>
            <dd class="font-semibold tabular-nums">{delimited_count(@detail.footprint.open_cases)}</dd>
          </div>
          <div>
            <dt class="text-xs text-slate-500">{gettext("Cold outreach")}</dt>
            <dd class={[
              "font-semibold tabular-nums",
              @detail.footprint.cold_outreach >= Vutuv.Chat.new_conversation_limit() &&
                "text-amber-700 dark:text-amber-300"
            ]}>
              {delimited_count(@detail.footprint.cold_outreach)} / {delimited_count(Vutuv.Chat.new_conversation_limit())}
            </dd>
          </div>
        </dl>
      </div>

      <div :if={@detail.cases != []} class="mt-5">
        <p class="card__label">{gettext("Report history")}</p>
        <ul class="mt-2 space-y-2">
          <li
            :for={mod_case <- @detail.cases}
            class="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-slate-50 px-3 py-2 text-sm ring-1 ring-slate-200 dark:bg-slate-800 dark:ring-slate-700"
          >
            <span>
              <span class="font-semibold">{status_badge(mod_case)}</span>
              <span class="ml-2 text-slate-500">
                {ngettext("%{count} report", "%{count} reports", length(mod_case.reports))}
              </span>
              <span class="ml-2 text-slate-500">
                <.local_time at={mod_case.inserted_at} id={"case-#{mod_case.id}-at"} format="%Y-%m-%d" />
              </span>
            </span>
            <.link
              navigate={~p"/admin/moderation/#{mod_case.id}"}
              class="font-semibold text-brand-600 hover:text-brand-700"
            >
              {gettext("Open case")} ›
            </.link>
          </li>
        </ul>
      </div>

      <div class="mt-5 flex flex-wrap gap-2 border-t border-slate-100 pt-4 dark:border-slate-800">
        <button
          :if={is_nil(@detail.posting.frozen_at)}
          type="button"
          phx-click="freeze"
          phx-value-id={@detail.posting.id}
          data-confirm={gettext("Freeze this posting? It disappears from the public board and its indexing but stays visible to its poster.")}
          class="rounded-lg bg-amber-100 px-3 py-1.5 text-sm font-semibold text-amber-800 hover:bg-amber-200 dark:bg-amber-900/40 dark:text-amber-200"
        >
          {gettext("Freeze")}
        </button>
        <button
          :if={not is_nil(@detail.posting.frozen_at)}
          type="button"
          phx-click="unfreeze"
          phx-value-id={@detail.posting.id}
          class="rounded-lg bg-emerald-100 px-3 py-1.5 text-sm font-semibold text-emerald-700 hover:bg-emerald-200 dark:bg-emerald-900/40 dark:text-emerald-200"
        >
          {gettext("Unfreeze")}
        </button>
        <button
          :if={Jobs.effective_status(@detail.posting) == :published}
          type="button"
          phx-click="close-posting"
          phx-value-id={@detail.posting.id}
          data-confirm={gettext("Close this posting? It ends the listing (a regular ending, not a deletion).")}
          class="rounded-lg bg-slate-100 px-3 py-1.5 text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200"
        >
          {gettext("Close")}
        </button>
        <button
          type="button"
          phx-click="delete"
          phx-value-id={@detail.posting.id}
          data-confirm={gettext("Delete this posting and everything it owns? This cannot be undone.")}
          class="ml-auto rounded-lg bg-rose-100 px-3 py-1.5 text-sm font-semibold text-rose-700 hover:bg-rose-200 dark:bg-rose-900/40 dark:text-rose-200"
        >
          {gettext("Delete")}
        </button>
      </div>
    </section>
    """
  end
end
