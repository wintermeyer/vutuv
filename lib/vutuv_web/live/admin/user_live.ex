defmodule VutuvWeb.Admin.UserLive do
  @moduledoc """
  The admin member browser (`/admin/users`): a live, filterable, searchable,
  sortable list of every account. **Every change updates the page with no
  reload** — search-as-you-type, instant registration/account filters, sortable
  columns, paging, and an inline "Verify identity" button that flips the row in
  place and emails the member.

  The filter/sort/page state lives in the **URL** (`push_patch`), so a particular
  view is shareable and the browser back button restores it; `handle_params/3` is
  the single loader. Lives in the `:admin` live_session (`on_mount :require_admin`,
  see the router) — the dead `:admin` pipeline 403s the disconnected render and
  the on_mount guards the socket.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.UserHelpers, only: [full_name: 1]

  alias Vutuv.Accounts
  alias Vutuv.Pages

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, gettext("Members"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = Accounts.admin_user_filters(params)
    total = Accounts.count_admin_users(filters)
    pages = Pages.total_pages(total, Accounts.admin_users_per_page())
    page = params |> page_param() |> min(pages)
    users = Accounts.list_admin_users(filters, %{"page" => page}, total: total)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:total, total)
     |> assign(:page, page)
     |> assign(:pages, pages)
     |> assign(:users, users)}
  end

  # ── Events (all but verify just rewrite the URL; handle_params reloads) ──

  @impl true
  def handle_event("filter", params, socket) do
    query =
      build_query(socket.assigns.filters, %{
        "q" => params["q"],
        "reg" => params["reg"],
        "flag" => params["flag"]
      })

    {:noreply, push_patch(socket, to: ~p"/admin/users?#{query}")}
  end

  def handle_event("sort", %{"col" => col}, socket) do
    filters = socket.assigns.filters
    dir = if filters.sort == col and filters.dir == "asc", do: "desc", else: "asc"
    query = build_query(filters, %{"sort" => col, "dir" => dir})
    {:noreply, push_patch(socket, to: ~p"/admin/users?#{query}")}
  end

  def handle_event("page", %{"page" => page}, socket) do
    query = build_query(socket.assigns.filters, %{"page" => to_string(page)})
    {:noreply, push_patch(socket, to: ~p"/admin/users?#{query}")}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/users")}
  end

  def handle_event("verify", %{"id" => id}, socket) do
    user = Enum.find(socket.assigns.users, &(&1.id == id))

    case user && Accounts.verify_identity(user) do
      {:ok, _verified} ->
        {:noreply,
         socket
         |> assign(:users, mark_verified(socket.assigns.users, id))
         |> put_flash(:info, gettext("Identity verified. The member has been emailed."))}

      _other ->
        {:noreply, put_flash(socket, :error, gettext("Could not verify this member."))}
    end
  end

  # Flip just the verified row in place, so the GUI updates without a reload.
  defp mark_verified(users, id) do
    Enum.map(users, fn user ->
      if user.id == id, do: %{user | identity_verified?: true}, else: user
    end)
  end

  # ── Helpers ──

  # The values `admin_user_filters/1` falls back to, kept OUT of the URL so a
  # shareable link carries only what actually deviates from the default view.
  @query_defaults %{
    "reg" => "pin",
    "flag" => "all",
    "sort" => "joined",
    "dir" => "desc",
    "page" => "1"
  }

  # The query map for a push_patch: the current filters with `overrides` applied,
  # then blanks and defaults dropped — so the default view is a bare
  # `/admin/users` and a filtered/sorted view is a clean, shareable URL. `page`
  # is omitted unless overridden, so any filter/sort change resets to page 1.
  defp build_query(filters, overrides) do
    %{
      "q" => filters.q,
      "reg" => filters.reg,
      "flag" => filters.flag,
      "sort" => filters.sort,
      "dir" => filters.dir
    }
    |> Map.merge(overrides)
    |> Enum.reject(fn {key, value} -> value in [nil, ""] or @query_defaults[key] == value end)
    |> Map.new()
  end

  defp page_param(params) do
    case Integer.parse(to_string(params["page"])) do
      {n, _} when n >= 1 -> n
      _ -> 1
    end
  end

  # The sortable columns, by `?sort=` value → header label.
  defp sortable_columns do
    [
      {"name", gettext("Member")},
      {"username", gettext("Username")},
      {"joined", gettext("Joined")}
    ]
  end

  defp sort_caret(filters, column) do
    cond do
      filters.sort != column -> ""
      filters.dir == "asc" -> " ▲"
      true -> " ▼"
    end
  end

  # Any filter narrowing the default view (drives the empty-state copy + Clear).
  defp filtered?(filters), do: filters.q != nil or filters.reg != "pin" or filters.flag != "all"

  defp member_name(user) do
    case String.trim(full_name(user)) do
      "" -> "@" <> (user.username || "")
      name -> name
    end
  end

  # The status badges a row carries, in order, as {label, tone} tuples.
  defp status_badges(user) do
    [
      user.admin? && {gettext("Admin"), :admin},
      user.identity_verified? && {gettext("Verified"), :verified},
      user.frozen_at && {gettext("Frozen"), :warn},
      user.suspended_until && {gettext("Suspended"), :warn},
      user.deactivated_at && {gettext("Deactivated"), :danger},
      user.unreachable_at && {gettext("Unreachable"), :danger}
    ]
    |> Enum.filter(& &1)
  end

  defp badge_class(:admin),
    do: "bg-brand-100 text-brand-700 dark:bg-brand-900/40 dark:text-brand-100"

  defp badge_class(:verified),
    do: "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/40 dark:text-emerald-200"

  defp badge_class(:warn),
    do: "bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-200"

  defp badge_class(:danger),
    do: "bg-rose-100 text-rose-700 dark:bg-rose-900/40 dark:text-rose-200"

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title={gettext("Members")}
      crumbs={[{gettext("Admin"), ~p"/admin"}, gettext("Members")]}
    />

    <div class="card-list">
      <section class="card scroll-mt-24" id="member-browser" phx-hook="PageScroll" data-page={@page}>
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h1 class="flex items-center gap-2">
            {gettext("Members")}
            <span class="rounded-full bg-slate-100 px-2 py-0.5 text-sm font-semibold text-slate-600 dark:bg-slate-800 dark:text-slate-300">
              {compact_count(@total)}
            </span>
          </h1>
          <button
            :if={filtered?(@filters)}
            type="button"
            phx-click="clear"
            id="clear-filters"
            class="text-sm font-semibold text-slate-600 hover:text-slate-800 dark:text-slate-400 dark:hover:text-slate-200"
          >
            {gettext("Clear filters")}
          </button>
        </div>
        <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
          {gettext(
            "Search by name, @handle or email, filter and sort. The list updates as you type, and the default shows PIN-registered members, newest first."
          )}
        </p>

        <%!-- Verifying a member emails them; this opens the local Swoosh mailbox
        so you can read that mail in dev. Dev-only via dev_mailbox?/0. --%>
        <p :if={dev_mailbox?()} class="mt-2 text-sm text-slate-600 dark:text-slate-400">
          {gettext("Development:")}
          <a
            href="/sent_emails"
            target="_blank"
            rel="noopener"
            class="font-semibold text-brand-600 hover:text-brand-700"
            id="dev-mailbox-link"
          >
            {gettext("open the dev email inbox")} ›
          </a>
        </p>

        <form
          id="member-filter"
          phx-change="filter"
          phx-submit="filter"
          class="mt-4 flex flex-wrap items-end gap-3"
        >
          <div class="grow">
            <label
              for="filter-q"
              class="block text-sm font-semibold text-slate-700 dark:text-slate-200"
            >
              {gettext("Search")}
            </label>
            <input
              type="search"
              name="q"
              id="filter-q"
              value={@filters.q}
              phx-debounce="250"
              autocomplete="off"
              placeholder={gettext("name, @handle or email")}
              class={input_class()}
            />
          </div>
          <div>
            <label
              for="filter-reg"
              class="block text-sm font-semibold text-slate-700 dark:text-slate-200"
            >
              {gettext("Registration")}
            </label>
            <select name="reg" id="filter-reg" class={input_class()}>
              <option value="pin" selected={@filters.reg == "pin"}>{gettext("PIN registered")}</option>
              <option value="unconfirmed" selected={@filters.reg == "unconfirmed"}>
                {gettext("Not confirmed")}
              </option>
              <option value="all" selected={@filters.reg == "all"}>
                {gettext("All registrations")}
              </option>
            </select>
          </div>
          <div>
            <label
              for="filter-flag"
              class="block text-sm font-semibold text-slate-700 dark:text-slate-200"
            >
              {gettext("Account")}
            </label>
            <select name="flag" id="filter-flag" class={input_class()}>
              <option value="all" selected={@filters.flag == "all"}>{gettext("All members")}</option>
              <option value="admin" selected={@filters.flag == "admin"}>{gettext("Admins")}</option>
              <option value="verified" selected={@filters.flag == "verified"}>
                {gettext("Identity-verified")}
              </option>
              <option value="unverified" selected={@filters.flag == "unverified"}>
                {gettext("Awaiting verification")}
              </option>
              <option value="frozen" selected={@filters.flag == "frozen"}>{gettext("Frozen")}</option>
              <option value="suspended" selected={@filters.flag == "suspended"}>
                {gettext("Suspended")}
              </option>
              <option value="deactivated" selected={@filters.flag == "deactivated"}>
                {gettext("Deactivated")}
              </option>
              <option value="unreachable" selected={@filters.flag == "unreachable"}>
                {gettext("Unreachable")}
              </option>
            </select>
          </div>
        </form>

        <p :if={@users == [] and filtered?(@filters)} class="card__empty">
          {gettext("No members match your filters.")}
        </p>
        <p :if={@users == [] and not filtered?(@filters)} class="card__empty">
          {gettext("Nothing here yet.")}
        </p>

        <div :if={@users != []} class="mt-4 card__tablewrap">
          <table class="pure-table">
            <thead>
              <tr>
                <th :for={{col, label} <- sortable_columns()}>
                  <button
                    type="button"
                    phx-click="sort"
                    phx-value-col={col}
                    class="font-semibold text-slate-700 hover:text-brand-700 dark:text-slate-200"
                  >
                    {label}{sort_caret(@filters, col)}
                  </button>
                </th>
                <th>{gettext("Status")}</th>
                <th></th>
              </tr>
            </thead>
            <tbody id="members">
              <tr :for={user <- @users} id={"user-#{user.id}"}>
                <td>
                  <.link navigate={~p"/#{user}"} class="flex items-center gap-2">
                    <.avatar user={user} size="xs" />
                    <span class="breakwrap font-medium">{member_name(user)}</span>
                  </.link>
                </td>
                <td class="breakwrap">
                  <.link navigate={~p"/#{user}"} class="text-brand-600 hover:text-brand-700">
                    @{user.username}
                  </.link>
                </td>
                <td class="whitespace-nowrap text-slate-600 dark:text-slate-400">
                  <.local_time at={user.inserted_at} id={"joined-#{user.id}"} format="%Y-%m-%d" />
                </td>
                <td>
                  <div class="flex flex-wrap gap-1">
                    <span class={[
                      "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-semibold",
                      if(user.email_confirmed?,
                        do:
                          "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/40 dark:text-emerald-200",
                        else: "bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-300"
                      )
                    ]}>
                      {if user.email_confirmed?, do: gettext("PIN"), else: gettext("Unconfirmed")}
                    </span>
                    <span
                      :for={{label, tone} <- status_badges(user)}
                      class={[
                        "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-semibold",
                        badge_class(tone)
                      ]}
                    >
                      {label}
                    </span>
                  </div>
                </td>
                <td class="text-right">
                  <button
                    :if={not user.identity_verified?}
                    type="button"
                    phx-click="verify"
                    phx-value-id={user.id}
                    data-confirm={gettext("Mark this member's identity as verified? They will be emailed.")}
                    class="rounded-lg bg-slate-100 px-3 py-1 text-xs font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
                  >
                    {gettext("Verify")}
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <nav
          :if={@pages > 1}
          class="mt-6 flex items-center justify-center gap-3 text-sm font-semibold"
          aria-label={gettext("Pagination")}
        >
          <button
            type="button"
            phx-click="page"
            phx-value-page={@page - 1}
            disabled={@page <= 1}
            id="prev-page"
            class="rounded-lg px-3 py-1.5 text-slate-600 hover:bg-slate-100 disabled:cursor-not-allowed disabled:opacity-40 dark:text-slate-300 dark:hover:bg-slate-800"
          >
            ‹ {gettext("Previous")}
          </button>
          <span class="text-slate-600 dark:text-slate-400">
            {gettext("Page %{page} of %{pages}", page: @page, pages: @pages)}
          </span>
          <button
            type="button"
            phx-click="page"
            phx-value-page={@page + 1}
            disabled={@page >= @pages}
            id="next-page"
            class="rounded-lg px-3 py-1.5 text-slate-600 hover:bg-slate-100 disabled:cursor-not-allowed disabled:opacity-40 dark:text-slate-300 dark:hover:bg-slate-800"
          >
            {gettext("Next")} ›
          </button>
        </nav>
      </section>
    </div>
    """
  end
end
