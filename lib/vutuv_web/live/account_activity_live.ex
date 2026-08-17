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
    only: [event_label: 1, detail: 1, factor_label: 1, by_someone_else?: 1, by_other_badge: 1]

  import VutuvWeb.BrowseTable

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
    dir = next_dir(socket.assigns.filters, browse_config(), col)
    {:noreply, patch(socket, %{"sort" => col, "dir" => dir})}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/settings/activity")}
  end

  defp patch(socket, overrides) do
    query = build_query(socket.assigns.filters, browse_config(), overrides)
    push_patch(socket, to: ~p"/settings/activity?#{query}")
  end

  # What the shared browse machinery (`VutuvWeb.BrowseTable`) needs to know
  # about this page: the filter vocabulary and the sort defaults, so blanks and
  # defaults are left out of the URL and the default view stays a bare
  # /settings/activity.
  defp browse_config do
    browse_config(
      filter_keys: [:q, :kind],
      default_sort: "time",
      default_dir: &AccountEvents.default_dir/1
    )
  end

  defp columns do
    [
      {"time", gettext("When"), nil},
      {"kind", gettext("What happened"), nil}
    ]
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
            <.count_pill id="activity-total" count={@total} />
          </div>
          <p class="mt-1 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
            {gettext(
              "Every change to your account: what changed, exactly when, from which device, and how it was confirmed. If a line surprises you, follow the link at the end of it."
            )}
          </p>

          <%= if @total == 0 and not filtered?(@filters, browse_config()) do %>
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
                  placeholder={gettext("device or detail")}
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
                :if={filtered?(@filters, browse_config())}
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
                    <.sort_header
                      :for={{col, header, class} <- columns()}
                      col={col}
                      label={header}
                      class={class}
                      filters={@filters}
                    />
                    <%!-- The "Device" column folds away below `sm`: the device
                    also rides under the sentence on a phone, and keeping the
                    column would push the timestamp — the fact the page exists
                    for — off the card edge. --%>
                    <th class={phone_hidden_class()}>{gettext("Device")}</th>
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
                        style={:datetime_seconds}
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
                      <.by_other_badge :if={by_someone_else?(event)}>
                        {gettext("Not by you")}
                      </.by_other_badge>
                      <%!-- On a phone the "Device" column is folded away, so its
                      content rides here instead of being lost. --%>
                      <span
                        :if={event.device}
                        class="block text-xs text-slate-600 sm:hidden dark:text-slate-400"
                      >
                        {event.device}
                      </span>
                    </td>
                    <td class={[phone_hidden_class(), "align-top text-slate-600 dark:text-slate-400"]}>
                      {event.device}
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

            <.browse_footer
              :if={@events != []}
              page={@page}
              per_page={@per_page}
              total={@total}
              path={~p"/settings/activity"}
              filters={@filters}
              config={browse_config()}
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
