defmodule VutuvWeb.Admin.CompanyLive do
  @moduledoc """
  The admin oversight dashboard for verified company pages (`/admin/companies`,
  issue #930). Overview tiles (live / pending / frozen), a searchable
  (name / alias / domain), status-filtered, paginated list, and a per-company
  detail drawer showing domains + verification state, roles, the rename / alias
  history and the claiming member. Actions — freeze / unfreeze / archive /
  delete — act reload-free (a `push_patch` re-runs the single `handle_params`
  loader). Filter/status/page/selection live in the URL, so a view is
  shareable. Lives in the `:admin` live_session.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.CompanyComponents, only: [role_label: 1, alias_kind_label: 1]
  import VutuvWeb.UserHelpers, only: [member_name: 1]

  alias Vutuv.Companies

  @statuses ~w(all active pending frozen archived)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, gettext("Company pages"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    status = if params["status"] in @statuses, do: params["status"], else: "all"
    q = blank_to_nil(params["q"])
    page = page_param(params)

    result =
      Companies.admin_companies_page(
        status: if(status == "all", do: nil, else: status),
        search: q,
        page: page
      )

    detail = params["selected"] && Companies.admin_company_detail(params["selected"])

    {:noreply,
     socket
     |> assign(:counts, Companies.admin_overview_counts())
     |> assign(:flagged_count, Companies.flagged_aliases_count())
     |> assign(:status, status)
     |> assign(:q, q)
     |> assign(:result, result)
     |> assign(:selected_id, params["selected"])
     |> assign(:detail, detail)}
  end

  # ── events: filter/status/select rewrite the URL; handle_params reloads ──

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

  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: patch_to(socket, %{"selected" => id}))}
  end

  def handle_event("close", _params, socket) do
    {:noreply, push_patch(socket, to: patch_to(socket, %{"selected" => nil}))}
  end

  def handle_event("page", %{"page" => page}, socket) do
    {:noreply, push_patch(socket, to: patch_to(socket, %{"page" => to_string(page)}))}
  end

  # ── events: the moderation/lifecycle actions ──

  def handle_event("freeze", %{"id" => id}, socket),
    do: act(socket, id, &Companies.admin_set_frozen(&1, true), gettext("Company frozen."))

  def handle_event("unfreeze", %{"id" => id}, socket),
    do: act(socket, id, &Companies.admin_set_frozen(&1, false), gettext("Company unfrozen."))

  def handle_event("archive", %{"id" => id}, socket),
    do: act(socket, id, &Companies.archive_company/1, gettext("Company archived."))

  def handle_event("delete", %{"id" => id}, socket) do
    case Companies.get_company(id) do
      nil ->
        {:noreply, socket}

      company ->
        {:ok, _} = Companies.delete_company(company)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Company deleted."))
         |> push_patch(to: patch_to(socket, %{"selected" => nil}))}
    end
  end

  defp act(socket, id, fun, message) do
    case Companies.get_company(id) do
      nil ->
        {:noreply, socket}

      company ->
        {:ok, _} = fun.(company)
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
        "selected" => socket.assigns.selected_id
      }
      |> Map.merge(overrides)
      |> Enum.reject(fn {key, value} ->
        value in [nil, ""] or (key == "status" and value == "all")
      end)
      |> Map.new()

    if query == %{}, do: ~p"/admin/companies", else: ~p"/admin/companies?#{query}"
  end

  defp blank_to_nil(value) do
    case value && String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp page_param(params) do
    case Integer.parse(to_string(params["page"])) do
      {n, _} when n >= 1 -> n
      _ -> 1
    end
  end

  defp status_chips, do: @statuses

  defp status_label("all"), do: gettext("All")
  defp status_label("active"), do: gettext("Live")
  defp status_label("pending"), do: gettext("Pending")
  defp status_label("frozen"), do: gettext("Frozen")
  defp status_label("archived"), do: gettext("Archived")

  defp company_status_badge(%{frozen_at: frozen} = _company) when not is_nil(frozen),
    do:
      {gettext("Frozen"), "bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-200"}

  defp company_status_badge(%{status: "active"}),
    do:
      {gettext("Live"),
       "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/40 dark:text-emerald-200"}

  defp company_status_badge(%{status: "pending"}),
    do: {gettext("Pending"), "bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-300"}

  defp company_status_badge(%{status: "archived"}),
    do: {gettext("Archived"), "bg-slate-100 text-slate-500 dark:bg-slate-800 dark:text-slate-400"}

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title={gettext("Company pages")}
      crumbs={[{gettext("Admin"), ~p"/admin"}, gettext("Company pages")]}
    />

    <div class="mb-6 grid grid-cols-3 gap-3">
      <.tile label={gettext("Live")} value={@counts.active} />
      <.tile label={gettext("Pending")} value={@counts.pending} />
      <.tile label={gettext("Frozen")} value={@counts.frozen} />
    </div>

    <p :if={@flagged_count > 0} id="flagged-aliases-note" class="mb-6 rounded-2xl bg-amber-50 px-4 py-3 text-sm text-amber-800 ring-1 ring-amber-200 dark:bg-amber-900/30 dark:text-amber-200 dark:ring-amber-800">
      {ngettext(
        "%{count} alias matches another verified company and is flagged for review. Open a company below to see it.",
        "%{count} aliases match another verified company and are flagged for review. Open a company below to see them.",
        @flagged_count
      )}
    </p>

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
        </div>

        <form id="company-filter" phx-change="filter" phx-submit="filter" class="mt-4">
          <input
            type="search"
            name="q"
            value={@q}
            phx-debounce="250"
            autocomplete="off"
            placeholder={gettext("Search name, alias or domain")}
            class={input_class()}
          />
        </form>

        <p :if={@result.entries == []} class="card__empty">{gettext("No company pages match.")}</p>

        <div :if={@result.entries != []} class="mt-4 card__tablewrap">
          <table class="pure-table">
            <thead>
              <tr>
                <th>{gettext("Company")}</th>
                <th>{gettext("City")}</th>
                <th>{gettext("Status")}</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={company <- @result.entries} id={"company-row-#{company.id}"}>
                <td class="breakwrap font-medium">{company.name}</td>
                <td class="breakwrap text-slate-600 dark:text-slate-400">{company.city}</td>
                <td>
                  <% {label, tone} = company_status_badge(company) %>
                  <span class={["inline-flex items-center rounded-full px-2 py-0.5 text-xs font-semibold", tone]}>{label}</span>
                </td>
                <td class="text-right">
                  <button
                    type="button"
                    phx-click="select"
                    phx-value-id={company.id}
                    class="text-sm font-semibold text-brand-600 hover:text-brand-700"
                  >
                    {gettext("Details")} ›
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <nav
          :if={@result.total_pages > 1}
          class="mt-6 flex items-center justify-center gap-3 text-sm font-semibold"
          aria-label={gettext("Pagination")}
        >
          <button
            type="button"
            phx-click="page"
            phx-value-page={@result.page - 1}
            disabled={@result.page <= 1}
            class="rounded-lg px-3 py-1.5 text-slate-600 hover:bg-slate-100 disabled:opacity-40 dark:text-slate-300 dark:hover:bg-slate-800"
          >
            ‹ {gettext("Previous")}
          </button>
          <span class="text-slate-600 dark:text-slate-400">
            {gettext("Page %{page} of %{pages}", page: @result.page, pages: @result.total_pages)}
          </span>
          <button
            type="button"
            phx-click="page"
            phx-value-page={@result.page + 1}
            disabled={@result.page >= @result.total_pages}
            class="rounded-lg px-3 py-1.5 text-slate-600 hover:bg-slate-100 disabled:opacity-40 dark:text-slate-300 dark:hover:bg-slate-800"
          >
            {gettext("Next")} ›
          </button>
        </nav>
      </section>

      {detail_card(assigns)}
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :integer, required: true)

  defp tile(assigns) do
    ~H"""
    <div class="rounded-2xl bg-white p-4 text-center shadow-sm ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800">
      <div class="text-2xl font-bold text-slate-900 dark:text-slate-100">{delimited_count(@value)}</div>
      <div class="text-xs font-semibold uppercase tracking-wide text-slate-500">{@label}</div>
    </div>
    """
  end

  defp detail_card(%{detail: nil} = assigns), do: ~H""

  defp detail_card(assigns) do
    ~H"""
    <section class="card" id="company-detail">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <h2 class="text-lg font-bold text-slate-900 dark:text-slate-100">{@detail.company.name}</h2>
          <p class="text-sm text-slate-600 dark:text-slate-400">
            <.link navigate={"/companies/#{@detail.company.slug}"} class="text-brand-600 hover:text-brand-700">
              /companies/{@detail.company.slug}
            </.link>
          </p>
        </div>
        <button type="button" phx-click="close" class="shrink-0 text-sm font-semibold text-slate-500 hover:text-slate-700 dark:hover:text-slate-300">
          {gettext("Close")}
        </button>
      </div>

      <dl class="mt-4 grid gap-4 sm:grid-cols-2">
        <div>
          <dt class="card__label">{gettext("Domains")}</dt>
          <dd class="mt-1 space-y-1 text-sm text-slate-700 dark:text-slate-300">
            <p :for={domain <- @detail.domains} class="flex flex-wrap items-center gap-2">
              <span class="font-mono">{domain.domain}</span>
              <span :if={domain.primary?} class="text-xs font-semibold text-brand-700 dark:text-brand-300">{gettext("primary")}</span>
              <span class={["text-xs font-semibold", if(domain.verified_at, do: "text-emerald-600 dark:text-emerald-300", else: "text-slate-500")]}>
                {if domain.verified_at, do: gettext("verified"), else: gettext("pending")}
              </span>
              <span :if={domain.last_checked_at} class="text-xs text-slate-500">
                <.local_time at={domain.last_checked_at} id={"detail-checked-#{domain.id}"} format="%Y-%m-%d" />
              </span>
            </p>
          </dd>
        </div>

        <div>
          <dt class="card__label">{gettext("Team")}</dt>
          <dd class="mt-1 space-y-1 text-sm text-slate-700 dark:text-slate-300">
            <p :for={role <- @detail.roles}>
              <.link navigate={"/#{role.user.username}"} class="text-brand-600 hover:text-brand-700">@{role.user.username}</.link>
              <span class="text-xs text-slate-500">{role_label(role.role)}</span>
            </p>
            <p :if={@detail.claimed_by} class="text-xs text-slate-500">
              {gettext("Claimed by")}: {member_name(@detail.claimed_by)}
            </p>
          </dd>
        </div>

        <div :if={@detail.aliases != []} class="sm:col-span-2">
          <dt class="card__label">{gettext("Names & aliases")}</dt>
          <dd class="mt-1 flex flex-wrap gap-2 text-sm">
            <span
              :for={company_name <- @detail.aliases}
              class={[
                "inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-semibold",
                if(company_name.flagged_at,
                  do: "bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-200",
                  else: "bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-300"
                )
              ]}
            >
              {company_name.name}
              <span class="opacity-70">· {alias_kind_label(company_name.kind)}</span>
              <span :if={company_name.flagged_at} title={gettext("Matches another verified company")}>⚑</span>
            </span>
          </dd>
        </div>
      </dl>

      <div class="mt-5 flex flex-wrap gap-2 border-t border-slate-100 pt-4 dark:border-slate-800">
        <button
          :if={is_nil(@detail.company.frozen_at)}
          type="button"
          phx-click="freeze"
          phx-value-id={@detail.company.id}
          data-confirm={gettext("Freeze this page? It disappears for the public but stays visible to its owner.")}
          class="rounded-lg bg-amber-100 px-3 py-1.5 text-sm font-semibold text-amber-800 hover:bg-amber-200 dark:bg-amber-900/40 dark:text-amber-200"
        >
          {gettext("Freeze")}
        </button>
        <button
          :if={not is_nil(@detail.company.frozen_at)}
          type="button"
          phx-click="unfreeze"
          phx-value-id={@detail.company.id}
          class="rounded-lg bg-emerald-100 px-3 py-1.5 text-sm font-semibold text-emerald-700 hover:bg-emerald-200 dark:bg-emerald-900/40 dark:text-emerald-200"
        >
          {gettext("Unfreeze")}
        </button>
        <button
          :if={@detail.company.status != "archived"}
          type="button"
          phx-click="archive"
          phx-value-id={@detail.company.id}
          data-confirm={gettext("Archive this page?")}
          class="rounded-lg bg-slate-100 px-3 py-1.5 text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200"
        >
          {gettext("Archive")}
        </button>
        <button
          type="button"
          phx-click="delete"
          phx-value-id={@detail.company.id}
          data-confirm={gettext("Delete this page and everything it owns? This cannot be undone.")}
          class="ml-auto rounded-lg bg-rose-100 px-3 py-1.5 text-sm font-semibold text-rose-700 hover:bg-rose-200 dark:bg-rose-900/40 dark:text-rose-200"
        >
          {gettext("Delete")}
        </button>
      </div>
    </section>
    """
  end
end
