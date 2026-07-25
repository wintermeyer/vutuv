defmodule VutuvWeb.Admin.ActivityLive do
  @moduledoc """
  The installation-wide account-activity log (`/admin/activity`, issue #1087):
  the support side of the member's own `/settings/activity`.

  It exists so "what happened to this account on Tuesday" can be answered from
  the admin area instead of from a database console — a member filter (name,
  @handle or email address), a free-text search over device / IP / kind /
  details, a kind filter, three sortable columns and numbered paging over the
  same rows the member sees on their own page.

  **Reading somebody else's activity is itself an act worth recording**, so this
  page logs its own access as an `"activity_log_viewed"` event on the *admin's*
  account: once when the page is opened, and once more per distinct member
  filter that actually returns rows — that is the moment a particular member's
  activity was really put on screen. It goes on the admin's own log rather than
  the member's on purpose: it is the admin's action, it belongs in the trail of
  what that admin did, and it is answerable to whoever reviews the admins.

  Filter, sort and page live in the **URL** (`push_patch`), so a view is
  shareable inside the team and the back button restores it. Lives in the
  `:admin` live_session (`on_mount :require_admin`, see the router) — the dead
  `:admin` pipeline 403s the disconnected render and the on_mount guards the
  socket.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.AccountEventText,
    only: [event_label: 1, detail: 1, factor_label: 1, by_someone_else?: 1]

  import VutuvWeb.UserHelpers, only: [member_name: 1]

  alias Vutuv.AccountEvents
  alias Vutuv.Pages

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Account activity"))
     |> assign(:kinds, AccountEvents.kinds_present())
     # Which member filters this session has already recorded an access for, so
     # a shared view reloaded five times does not file five identical rows.
     |> assign(:logged_members, MapSet.new())
     |> record_access(nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = AccountEvents.admin_filters(params)
    per_page = AccountEvents.events_per_page()
    total = AccountEvents.admin_count(filters)
    page = Pages.effective_page(params, total, per_page)

    events =
      AccountEvents.admin_page(filters, %{"page" => page}, total: total, per_page: per_page)

    socket =
      socket
      |> assign(:filters, filters)
      |> assign(:total, total)
      |> assign(:page, page)
      |> assign(:per_page, per_page)
      |> assign(:events, events)

    # Only once the filter actually put a member's rows on screen: a search that
    # matches nobody revealed nothing, and logging it would bury the accesses
    # that did.
    if filters.member && events != [] do
      {:noreply, record_access(socket, filters.member)}
    else
      {:noreply, socket}
    end
  end

  # ── Events (every one just rewrites the URL; handle_params reloads) ──

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     patch(socket, %{
       "q" => params["q"],
       "kind" => params["kind"],
       "member" => params["member"]
     })}
  end

  def handle_event("sort", %{"col" => col}, socket) do
    filters = socket.assigns.filters
    dir = if filters.sort == col, do: flip(filters.dir), else: AccountEvents.default_dir(col)
    {:noreply, patch(socket, %{"sort" => col, "dir" => dir})}
  end

  # A handle in a row is a filter you can click: "show me everything else that
  # happened to this account" is the question every support conversation asks
  # next.
  def handle_event("filter_member", %{"handle" => handle}, socket) do
    {:noreply, patch(socket, %{"member" => handle})}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/activity")}
  end

  # The page's own audit line. Deduped per socket so paging and sorting inside
  # one already-recorded view do not file a row each.
  defp record_access(socket, member) do
    if MapSet.member?(socket.assigns.logged_members, member) do
      socket
    else
      # Only on the live socket: the disconnected render is thrown away
      # milliseconds later and would double every entry.
      if connected?(socket) do
        AccountEvents.record(socket.assigns.current_user, "activity_log_viewed",
          details: if(member, do: %{member: member}, else: %{})
        )
      end

      update(socket, :logged_members, &MapSet.put(&1, member))
    end
  end

  defp flip("asc"), do: "desc"
  defp flip(_desc), do: "asc"

  defp patch(socket, overrides) do
    query = build_query(socket.assigns.filters, overrides)
    push_patch(socket, to: ~p"/admin/activity?#{query}")
  end

  defp build_query(filters, overrides \\ %{}) do
    %{
      "q" => filters.q,
      "kind" => filters.kind,
      "member" => filters.member,
      "sort" => filters.sort,
      "dir" => filters.dir
    }
    |> Map.merge(overrides)
    |> drop_defaults()
  end

  defp drop_defaults(query) do
    sort = query["sort"] || "time"

    query
    |> Enum.reject(fn
      {_key, value} when value in [nil, ""] -> true
      {"sort", "time"} -> true
      {"dir", dir} -> dir == AccountEvents.default_dir(sort)
      {"page", "1"} -> true
      {_key, _value} -> false
    end)
    |> Map.new()
  end

  defp filtered?(filters),
    do: filters.q != nil or filters.kind != nil or filters.member != nil

  defp columns do
    [
      {"time", gettext("When")},
      {"member", gettext("Member")},
      {"kind", gettext("What happened")}
    ]
  end

  defp sort_caret(filters, column) do
    cond do
      filters.sort != column -> ""
      filters.dir == "asc" -> " ▲"
      true -> " ▼"
    end
  end

  defp aria_sort(%{sort: column, dir: "asc"}, column), do: "ascending"
  defp aria_sort(%{sort: column}, column), do: "descending"
  defp aria_sort(_filters, _column), do: "none"

  defp range_first(page, per_page, total) when total > 0, do: (page - 1) * per_page + 1
  defp range_first(_page, _per_page, _total), do: 0

  defp range_last(page, per_page, total), do: min(page * per_page, total)

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title={gettext("Account activity")}
      crumbs={[{gettext("Admin"), ~p"/admin"}, gettext("Account activity")]}
    />

    <div class="card-list">
      <section class="card">
        <p class="text-sm leading-relaxed text-slate-600 dark:text-slate-400">
          {gettext(
            "What changed on which account, when, from where and how it was confirmed - the same log every member sees for themselves. Opening it is recorded in your own activity log."
          )}
        </p>

        <form
          id="activity-filter"
          phx-change="filter"
          phx-submit="filter"
          class="mt-4 flex flex-wrap items-end gap-3"
        >
          <div class="min-w-48 grow">
            <label
              for="filter-member"
              class="block text-sm font-semibold text-slate-700 dark:text-slate-200"
            >
              {gettext("Member")}
            </label>
            <input
              type="search"
              name="member"
              id="filter-member"
              value={@filters.member}
              phx-debounce="250"
              autocomplete="off"
              placeholder={gettext("name, @handle or email")}
              class={input_class()}
            />
          </div>
          <div class="min-w-48 grow">
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
              placeholder={gettext("device, IP address or detail")}
              class={input_class()}
            />
          </div>
          <div :if={@kinds != []}>
            <label
              for="filter-kind"
              class="block text-sm font-semibold text-slate-700 dark:text-slate-200"
            >
              {gettext("Kind")}
            </label>
            <select name="kind" id="filter-kind" class={input_class()}>
              <option value="" selected={is_nil(@filters.kind)}>{gettext("Everything")}</option>
              <option
                :for={kind <- Enum.sort_by(@kinds, &event_label/1)}
                value={kind}
                selected={@filters.kind == kind}
              >
                {event_label(kind)}
              </option>
            </select>
          </div>
          <button
            :if={filtered?(@filters)}
            type="button"
            phx-click="clear"
            id="clear-filters"
            class="py-2 text-sm font-semibold text-slate-600 hover:text-slate-800 dark:text-slate-400 dark:hover:text-slate-200"
          >
            {gettext("Clear filters")}
          </button>
        </form>

        <p :if={@events == []} class="card__empty" id="no-activity">
          <%= if filtered?(@filters) do %>
            {gettext("Nothing matches that. Try a shorter search, or clear the filters.")}
          <% else %>
            {gettext("No account activity has been recorded yet.")}
          <% end %>
        </p>

        <div :if={@events != []} class="card__tablewrap mt-4">
          <table class="pure-table">
            <thead>
              <tr>
                <th :for={{col, header} <- columns()} aria-sort={aria_sort(@filters, col)}>
                  <button
                    type="button"
                    phx-click="sort"
                    phx-value-col={col}
                    id={"sort-#{col}"}
                    class="font-semibold text-slate-700 hover:text-brand-700 dark:text-slate-200 dark:hover:text-brand-300"
                  >
                    {header}{sort_caret(@filters, col)}
                  </button>
                </th>
                <th>{gettext("Where from")}</th>
              </tr>
            </thead>
            <tbody id="activity-events">
              <tr :for={event <- @events} id={"event-#{event.id}"}>
                <td class="whitespace-nowrap align-top text-slate-600 dark:text-slate-400">
                  <.local_time
                    at={event.inserted_at}
                    id={"at-#{event.id}"}
                    precision="second"
                    format="%Y-%m-%d %H:%M:%S"
                  />
                </td>
                <td class="align-top">
                  <button
                    type="button"
                    phx-click="filter_member"
                    phx-value-handle={event.user.username}
                    title={gettext("Show only this member")}
                    class="block whitespace-nowrap text-left text-slate-600 underline decoration-dotted underline-offset-2 hover:text-brand-700 dark:text-slate-400 dark:hover:text-brand-300"
                  >
                    @{event.user.username}
                  </button>
                  <span class="block text-xs text-slate-600 dark:text-slate-400">
                    {member_name(event.user)}
                  </span>
                </td>
                <td class="align-top">
                  <span class="block font-medium text-slate-800 dark:text-slate-100">
                    {event_label(event)}
                  </span>
                  <span
                    :if={detail(event)}
                    class="breakwrap block text-slate-600 dark:text-slate-400"
                    data-event-detail
                  >
                    {detail(event)}
                  </span>
                  <span
                    :if={factor_label(event)}
                    class="block text-xs text-slate-600 dark:text-slate-400"
                  >
                    {gettext("Confirmed")} {factor_label(event)}
                  </span>
                  <span
                    :if={by_someone_else?(event)}
                    data-event-by-other
                    class="mt-1 inline-flex items-center rounded-full bg-amber-50 px-2 py-0.5 text-xs font-semibold text-amber-800 dark:bg-amber-900/30 dark:text-amber-200"
                  >
                    {gettext("By %{name}", name: "@#{actor_handle(event)}")}
                  </span>
                </td>
                <td class="align-top text-slate-600 dark:text-slate-400">
                  <span :if={event.device} class="block">{event.device}</span>
                  <span :if={event.ip_address} class="block break-all text-xs">
                    {event.ip_address}
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <p :if={@events != []} class="mt-3 text-xs text-slate-600 dark:text-slate-400">
          {gettext("Showing %{first}-%{last} of %{total}.",
            first: delimited_count(range_first(@page, @per_page, @total)),
            last: delimited_count(range_last(@page, @per_page, @total)),
            total: delimited_count(@total)
          )}
        </p>

        <.pager
          params={%{"page" => @page}}
          total={@total}
          per_page={@per_page}
          path={~p"/admin/activity"}
          query={build_query(@filters)}
        />
      </section>
    </div>
    """
  end

  # The acting admin's handle, or a plain marker when that account has since
  # been deleted (the FK nils rather than taking the log row with it).
  defp actor_handle(%{actor_user: %{username: username}}), do: username
  defp actor_handle(_event), do: gettext("a deleted account")
end
