defmodule VutuvWeb.AccountActivityLive do
  @moduledoc """
  The member's own account-activity log (`/settings/activity`, issue #1087).

  It answers one question — "did I do that, and when?" — so everything on the
  page serves it: one row per event, newest first, each reading as a sentence
  with a **to-the-second** timestamp in the reader's own timezone, the device
  and IP it came from, how it was confirmed, and, when it was not the member's
  own doing, who did it. Every row ends in a quiet "Not you?" link into
  `/settings/security`, where the levers are (sign every other device out, add
  a passkey, check the address list) — a log you cannot act on is a curiosity,
  not a safeguard.

  Search, the kind filter, the sort and the page all live in the **URL**
  (`push_patch`), so a particular view is shareable — handing support a link is
  the easiest possible "here, look at this" — and the back button restores it.
  `handle_params/3` is the single loader and the query work stays in
  `Vutuv.AccountEvents`.

  Owner-only by construction: it lives in the `/settings` scope and reads only
  `current_user`'s rows.
  """

  use VutuvWeb, :live_view

  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  import VutuvWeb.AccountEventText,
    only: [event_label: 1, detail: 1, factor_label: 1, by_someone_else?: 1]

  alias Vutuv.AccountEvents
  alias Vutuv.Pages

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, gettext("Account activity"))
     |> assign(:user, user)
     |> assign(:kinds, AccountEvents.kinds_present(user))
     |> assign(:retention_days, AccountEvents.retention_days())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    user = socket.assigns.user
    filters = AccountEvents.filters(params)
    per_page = AccountEvents.events_per_page()
    total = AccountEvents.count(user, filters)
    page = Pages.effective_page(params, total, per_page)

    events =
      AccountEvents.page(user, filters, %{"page" => page}, total: total, per_page: per_page)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:total, total)
     |> assign(:page, page)
     |> assign(:per_page, per_page)
     |> assign(:events, events)}
  end

  # ── Events (every one just rewrites the URL; handle_params reloads) ──

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, patch(socket, %{"q" => params["q"], "kind" => params["kind"]})}
  end

  def handle_event("sort", %{"col" => col}, socket) do
    filters = socket.assigns.filters
    dir = if filters.sort == col, do: flip(filters.dir), else: AccountEvents.default_dir(col)
    {:noreply, patch(socket, %{"sort" => col, "dir" => dir})}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/settings/activity")}
  end

  defp flip("asc"), do: "desc"
  defp flip(_desc), do: "asc"

  defp patch(socket, overrides) do
    query = build_query(socket.assigns.filters, overrides)
    push_patch(socket, to: ~p"/settings/activity?#{query}")
  end

  # Blanks and defaults are left out, so the default view is a bare
  # /settings/activity and a filtered one is a clean, shareable URL.
  defp build_query(filters, overrides \\ %{}) do
    %{"q" => filters.q, "kind" => filters.kind, "sort" => filters.sort, "dir" => filters.dir}
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

  # Any narrowing of the full log — what "Clear" and the empty state key on. A
  # sort is not a filter: it hides nothing.
  defp filtered?(filters), do: filters.q != nil or filters.kind != nil

  # The "Where from" column folds away below `sm`: the device and IP also ride
  # under the sentence on a phone, and keeping the column would push the
  # timestamp — the fact the page exists for — off the card edge.
  @source_column_class "hidden sm:table-cell"

  defp source_column_class, do: @source_column_class

  defp columns do
    [
      {"time", gettext("When"), nil},
      {"kind", gettext("What happened"), nil}
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

  # The device and the IP as one muted line. Either can be missing (an event
  # recorded off a request has neither), so the line collapses rather than
  # rendering a stray separator.
  defp source_line(event) do
    [event.device, event.ip_address] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.settings_shell
      user={@user}
      active={:activity}
      title={gettext("Account activity")}
      crumbs={[{gettext("Settings"), ~p"/settings"}, gettext("Account activity")]}
    >
      <div class="space-y-6">
        <.card>
          <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
            <.section_title>{gettext("Account activity")}</.section_title>
            <span
              id="activity-total"
              class="rounded-full bg-slate-100 px-2 py-0.5 text-sm font-semibold text-slate-600 dark:bg-slate-800 dark:text-slate-300"
            >
              {delimited_count(@total)}
            </span>
          </div>
          <p class="mt-1 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
            {gettext(
              "Every change to your account: what changed, exactly when, from which device, and how it was confirmed. If a line surprises you, follow the link at the end of it."
            )}
          </p>

          <%= if @total == 0 and not filtered?(@filters) do %>
            <p class="mt-4 text-sm text-slate-600 dark:text-slate-400" id="no-activity">
              {gettext(
                "Nothing here yet. The next time you sign in or change a setting, it will be listed here."
              )}
            </p>
          <% else %>
            <%!-- One form for both controls, so typing and picking a kind are
            the same round trip. Debounced: every keystroke is a query. --%>
            <form
              id="activity-filter"
              phx-change="filter"
              phx-submit="filter"
              class="mt-4 flex flex-wrap items-end gap-3"
            >
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
                  <option value="" selected={is_nil(@filters.kind)}>
                    {gettext("Everything")}
                  </option>
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

            <p
              :if={@events == []}
              class="mt-4 text-sm text-slate-600 dark:text-slate-400"
              id="no-matches"
            >
              {gettext("Nothing matches that. Try a shorter search, or clear the filters.")}
            </p>

            <div :if={@events != []} class="card__tablewrap mt-4">
              <table class="pure-table">
                <thead>
                  <tr>
                    <th
                      :for={{col, header, class} <- columns()}
                      aria-sort={aria_sort(@filters, col)}
                      class={class}
                    >
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
                    <th class={source_column_class()}>{gettext("Where from")}</th>
                    <th><span class="sr-only">{gettext("Was this you?")}</span></th>
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
                      <%!-- The one line on this page that has to shout: somebody
                      other than the member made this change. --%>
                      <span
                        :if={by_someone_else?(event)}
                        data-event-by-other
                        class="mt-1 inline-flex items-center rounded-full bg-amber-50 px-2 py-0.5 text-xs font-semibold text-amber-800 dark:bg-amber-900/30 dark:text-amber-200"
                      >
                        {gettext("Not by you")}
                      </span>
                      <%!-- On a phone the "Where from" column is folded away, so
                      its content rides here instead of being lost. --%>
                      <span
                        :if={source_line(event) != ""}
                        class="block text-xs text-slate-600 sm:hidden dark:text-slate-400"
                      >
                        {source_line(event)}
                      </span>
                    </td>
                    <td class={[source_column_class(), "align-top text-slate-600 dark:text-slate-400"]}>
                      <span :if={event.device} class="block">{event.device}</span>
                      <span :if={event.ip_address} class="block break-all text-xs">
                        {event.ip_address}
                      </span>
                    </td>
                    <td class="whitespace-nowrap align-top text-right">
                      <.link
                        navigate={~p"/settings/security"}
                        class="text-xs font-semibold text-slate-600 underline decoration-dotted underline-offset-2 hover:text-brand-700 dark:text-slate-400 dark:hover:text-brand-300"
                      >
                        {gettext("Not you?")}
                      </.link>
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
              path={~p"/settings/activity"}
              query={build_query(@filters)}
            />
          <% end %>
        </.card>

        <.card>
          <.section_title>{gettext("If something here was not you")}</.section_title>
          <p class="mt-1 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
            {gettext(
              "Sign every other device out, then check which passkeys, codes and email addresses your account has. All of it is on the sign-in & security page."
            )}
          </p>
          <p class="mt-3 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
            {ngettext(
              "This log keeps one day of history.",
              "This log keeps %{formatted} days of history.",
              @retention_days,
              formatted: delimited_count(@retention_days)
            )}
            {gettext("It is part of your data download, and it is deleted with your account.")}
          </p>
          <.card_footer_link href={~p"/settings/security"}>
            {gettext("Sign-in & security")}
          </.card_footer_link>
        </.card>
      </div>
    </.settings_shell>
    """
  end
end
