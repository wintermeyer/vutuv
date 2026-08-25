defmodule VutuvWeb.ImportConnectionsLive do
  @moduledoc """
  "Which of my LinkedIn contacts are already here?" (issue #1476), at
  `/settings/import/linkedin/connections`.

  The member uploads the same data-export ZIP the profile importer takes, this
  page reads **only** `Connections.csv` out of it, and answers with vutuv
  members — never the other way round. Nothing is imported, nobody is invited,
  no email is sent, and no profile is created for a contact who is not here.

  ## Its own page, its own upload

  The profile importer (`VutuvWeb.ImportController`) fills in *your* profile;
  this fills in *your feed*. Two different jobs, and most members will want one
  of them, so this is a page of its own rather than a fourth step in that
  wizard — which also means there is no parsed-archive state to hand between
  two requests. The two link to each other.

  ## What is kept: nothing

  The archive is read into memory and dropped, `Vutuv.Imports.LinkedIn.parse_connections/2`
  keeps only the two identifiers a match can rest on, and the match list lives
  in this socket and dies with the page. There is no table behind it, so a
  reconnect (or a reload) means uploading again — the follows already made are
  of course kept, because those are ordinary follows. The copy says so rather
  than promising a list that comes back.

  ## Following

  Every row carries the normal follow pill, and the selection plus **Follow
  selected** is a shortcut for pressing many of them — `Vutuv.Social.follow_many/2`
  makes each one an ordinary follow with its ordinary notification. Nothing is
  preselected and nothing follows automatically: uploading a file must never be
  the act that follows 800 people. The batch is capped (`@max_selection`) so one
  press stays a bounded piece of work; "select all" says how many it took.
  """

  use VutuvWeb, :live_view

  require Logger

  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  alias Vutuv.Imports.ConnectionMatch
  alias Vutuv.Imports.LinkedIn
  alias Vutuv.Pages
  alias Vutuv.Social
  alias VutuvWeb.RateLimit
  alias VutuvWeb.UserHelpers

  # Mirrors the profile importer's cap, since it is the same archive.
  @max_upload_bytes 50_000_000
  @per_page 50
  # How many members one press of "Follow selected" may follow. Each follow is
  # an insert plus a notification, so an unbounded press would hold the socket
  # for seconds; and a pause between batches is the right shape for an act this
  # public anyway. Everything still selectable stays selectable afterwards.
  @max_selection 500

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Find your contacts"))
     |> assign(:user, socket.assigns.current_user)
     |> assign(:max_upload_bytes, @max_upload_bytes)
     |> assign(:per_page, @per_page)
     |> reset_results()
     |> allow_upload(:archive,
       accept: ~w(.zip),
       max_entries: 1,
       max_file_size: @max_upload_bytes
     )}
  end

  # The upload stage, and what every "start over" returns to.
  defp reset_results(socket) do
    socket
    |> assign(:matches, nil)
    |> assign(:following_by_id, %{})
    |> assign(:work_info_by_id, %{})
    |> assign(:selected, MapSet.new())
    |> assign(:query, "")
    |> assign(:filter, "new")
    |> assign(:page, 1)
    |> assign(:error, nil)
  end

  # ── Upload → match ────────────────────────────────────────────────────────

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, assign(socket, :error, nil)}

  def handle_event("analyze", _params, socket) do
    case RateLimit.check_linkedin_import(socket.assigns.user) do
      :ok ->
        {:noreply, analyze(socket)}

      :rate_limited ->
        {:noreply,
         assign(
           socket,
           :error,
           gettext("You have analysed a lot of archives just now. Please try again later.")
         )}
    end
  end

  def handle_event("start_over", _params, socket), do: {:noreply, reset_results(socket)}

  # ── Narrowing the list ────────────────────────────────────────────────────

  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, socket |> assign(:query, query) |> assign(:page, 1)}
  end

  def handle_event("filter", %{"filter" => filter}, socket)
      when filter in ~w(new following all) do
    {:noreply, socket |> assign(:filter, filter) |> assign(:page, 1)}
  end

  def handle_event("page", %{"page" => page}, socket) do
    {:noreply, assign(socket, :page, sanitize_page(page, socket))}
  end

  # ── Selecting ─────────────────────────────────────────────────────────────

  def handle_event("toggle", %{"id" => id}, socket) do
    selected = socket.assigns.selected

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, :selected, selected)}
  end

  # "Select all" means the whole filtered list, not the page in front of you:
  # with a thousand rows the visible fifty are never what the member meant. The
  # cap is applied here rather than at the follow, so the count on the button
  # and the count that will be followed are the same number.
  def handle_event("select_all", _params, socket) do
    ids =
      socket
      |> selectable()
      |> Enum.take(@max_selection)
      |> Enum.map(& &1.user.id)

    {:noreply, assign(socket, :selected, MapSet.new(ids))}
  end

  def handle_event("select_none", _params, socket) do
    {:noreply, assign(socket, :selected, MapSet.new())}
  end

  # ── Following ─────────────────────────────────────────────────────────────

  def handle_event("follow_selected", _params, socket) do
    %{user: user, selected: selected} = socket.assigns
    followed = Social.follow_many(user, MapSet.to_list(selected))

    {:noreply,
     socket
     |> assign(:selected, MapSet.new())
     |> refresh_following()
     |> put_flash(:info, followed_message(followed))}
  end

  def handle_event("follow", %{"followee" => followee_id}, socket) do
    _ = Social.follow(socket.assigns.user, followee_id)
    {:noreply, refresh_following(socket)}
  end

  def handle_event("unfollow", %{"id" => follow_id}, socket) do
    Social.unfollow!(socket.assigns.user.id, follow_id)
    {:noreply, refresh_following(socket)}
  end

  defp analyze(socket) do
    user = socket.assigns.user

    results =
      consume_uploaded_entries(socket, :archive, fn %{path: path}, _entry ->
        {:ok, LinkedIn.parse_connections_file(path)}
      end)

    case results do
      [{:ok, contacts}] -> assign_matches(socket, user, contacts)
      [{:error, reason}] -> assign(socket, :error, upload_error(reason))
      [] -> assign(socket, :error, gettext("Please choose your LinkedIn export ZIP first."))
    end
  rescue
    error ->
      Logger.error(
        "LinkedIn contact match failed: " <> Exception.format(:error, error, __STACKTRACE__)
      )

      assign(socket, :error, gettext("The file could not be read. Please try again."))
  end

  defp assign_matches(socket, user, contacts) do
    matches = ConnectionMatch.find(user, contacts)

    socket
    |> assign(:matches, matches)
    |> assign(:error, nil)
    |> assign(:page, 1)
    |> assign(:selected, MapSet.new())
    |> assign(
      :work_info_by_id,
      UserHelpers.work_information_map(Enum.map(matches, & &1.user), 45)
    )
    |> refresh_following()
  end

  # One query for the whole page's follow state, re-asked after every follow or
  # unfollow so the pills and the "already following" filter agree.
  defp refresh_following(%{assigns: %{matches: nil}} = socket), do: socket

  defp refresh_following(socket) do
    people = Enum.map(socket.assigns.matches, & &1.user)
    assign(socket, :following_by_id, UserHelpers.following_map(socket.assigns.user, people))
  end

  defp upload_error(:archive_too_large),
    do: gettext("That archive is too large or has too many files to read safely.")

  defp upload_error(_reason), do: gettext("That does not look like a LinkedIn data export ZIP.")

  defp followed_message(0), do: gettext("Nobody new to follow: you already follow them.")

  defp followed_message(count) do
    ngettext(
      "You now follow one more member.",
      "You now follow %{formatted} more members.",
      count,
      formatted: delimited_count(count)
    )
  end

  # ── The list the page is showing ──────────────────────────────────────────

  # The filtered list, in full. Everything the toolbar reports (the count, what
  # "select all" takes, what the pager pages through) is derived from this one
  # function, so the numbers cannot drift apart.
  defp visible(%{assigns: assigns}) do
    Enum.filter(assigns.matches, fn match ->
      matches_filter?(match, assigns.filter, assigns.following_by_id) and
        matches_query?(match, assigns.query)
    end)
  end

  # What "select all" may take: never someone the member already follows —
  # pressing it must not be able to re-follow, and it would waste the cap.
  defp selectable(socket) do
    Enum.reject(socket |> visible(), &following?(&1, socket.assigns.following_by_id))
  end

  defp matches_filter?(match, "new", following), do: not following?(match, following)
  defp matches_filter?(match, "following", following), do: following?(match, following)
  defp matches_filter?(_match, _filter, _following), do: true

  defp following?(%{user: user}, following), do: Map.has_key?(following, user.id)

  defp matches_query?(_match, ""), do: true

  defp matches_query?(%{user: user}, query) do
    user
    |> UserHelpers.full_name()
    |> String.downcase()
    |> String.contains?(String.downcase(query))
  end

  defp page_slice(matches, page) do
    Enum.slice(matches, (page - 1) * @per_page, @per_page)
  end

  defp sanitize_page(page, socket) do
    total_pages = Pages.total_pages(length(visible(socket)), @per_page)

    case Integer.parse(to_string(page)) do
      {number, _rest} -> number |> max(1) |> min(total_pages)
      :error -> 1
    end
  end

  # ── Render ────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <.settings_shell
      user={@user}
      active={:import_connections}
      title={gettext("Find your LinkedIn contacts")}
    >
      <div class="max-w-3xl space-y-6">
        <.upload_card :if={is_nil(@matches)} {assigns} />
        <.results_card :if={@matches} {assigns} />
      </div>
    </.settings_shell>
    """
  end

  defp upload_card(assigns) do
    ~H"""
    <.card>
      <.section_title>{gettext("Who of your LinkedIn contacts is already here?")}</.section_title>
      <p class="mt-2 text-sm text-slate-600 dark:text-slate-400">
        {gettext(
          "Your LinkedIn data export lists your contacts. We read that list, look for the people among them who are already vutuv members, and show you who they are. You decide who to follow."
        )}
      </p>

      <%!-- The three promises that make this bearable, said before the upload
      button rather than in a privacy page nobody opens. --%>
      <ul class="mt-4 space-y-1.5 text-sm text-slate-700 dark:text-slate-300">
        <li>{gettext("Nobody is invited and no email is sent.")}</li>
        <li>{gettext("Nothing is added to your profile.")}</li>
        <li>
          {gettext(
            "Nothing is stored: we read the file, show you the result, and keep neither your contacts nor the list."
          )}
        </li>
      </ul>

      <p class="mt-4 text-sm text-slate-600 dark:text-slate-400">
        {gettext(
          "We only recognise someone by an email address they published here, or by the LinkedIn profile they linked from their vutuv profile. We never guess by name, so you will not be offered a stranger who happens to share a name with someone you know."
        )}
      </p>

      <p class="mt-4 text-sm text-slate-600 dark:text-slate-400">
        {gettext("It is the same ZIP file the profile import uses.")}
        <.link
          navigate={~p"/settings/import/linkedin"}
          class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
        >
          {gettext("How to request it from LinkedIn")}
        </.link>
      </p>

      <form
        id="linkedin-connections-form"
        phx-submit="analyze"
        phx-change="validate"
        class="mt-6 space-y-4"
      >
        <label
          data-dropzone
          phx-drop-target={@uploads.archive.ref}
          class="group flex cursor-pointer flex-col items-center justify-center gap-2 rounded-xl border-2 border-dashed border-slate-300 bg-slate-50 px-6 py-10 text-center transition-colors hover:border-brand-400 hover:bg-brand-50 has-[:focus-visible]:border-brand-500 has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-brand-500 dark:border-slate-700 dark:bg-slate-800/50 dark:hover:border-brand-500 dark:hover:bg-slate-800"
        >
          <svg
            class="h-8 w-8 text-slate-400 transition-colors group-hover:text-brand-500 dark:text-slate-500"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            stroke-width="1.5"
            aria-hidden="true"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M3 16.5v2.25A2.25 2.25 0 0 0 5.25 21h13.5A2.25 2.25 0 0 0 21 18.75V16.5m-13.5-9L12 3m0 0 4.5 4.5M12 3v13.5"
            />
          </svg>
          <span class="text-sm text-slate-600 dark:text-slate-400">
            {gettext("Drag your ZIP file here, or click to choose one.")}
          </span>
          <span
            :for={entry <- @uploads.archive.entries}
            class="text-sm font-medium text-slate-900 dark:text-slate-100"
          >
            {entry.client_name}
          </span>
          <span class="text-xs text-slate-600 dark:text-slate-400">
            {gettext("ZIP file, up to 50 MB.")}
          </span>
          <.live_file_input upload={@uploads.archive} class="sr-only" />
        </label>

        <%!-- Both error levels: a too-large or non-ZIP file is an *entry*
        error, so asking the upload alone reports nothing and the member is
        left with a button that quietly does nothing. --%>
        <p
          :for={err <- upload_errors(@uploads.archive)}
          class="text-sm font-medium text-red-600 dark:text-red-400"
        >
          {upload_error_message(err)}
        </p>
        <%= for entry <- @uploads.archive.entries, err <- upload_errors(@uploads.archive, entry) do %>
          <p class="text-sm font-medium text-red-600 dark:text-red-400">
            {upload_error_message(err)}
          </p>
        <% end %>
        <p :if={@error} class="text-sm font-medium text-red-600 dark:text-red-400">{@error}</p>

        <.button type="submit" phx-disable-with={gettext("Reading…")} class="w-full sm:w-auto">
          {gettext("Find my contacts")}
        </.button>
      </form>
    </.card>
    """
  end

  defp results_card(assigns) do
    shown = visible(%{assigns: assigns})
    total = length(shown)

    assigns =
      assigns
      |> assign(:shown, page_slice(shown, assigns.page))
      |> assign(:total, total)
      |> assign(:total_pages, Pages.total_pages(total, @per_page))
      |> assign(:found, length(assigns.matches))
      |> assign(:selectable_count, min(length(selectable(%{assigns: assigns})), @max_selection))
      |> assign(:selected_count, MapSet.size(assigns.selected))

    ~H"""
    <.card>
      <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <.section_title>{gettext("Your contacts on vutuv")}</.section_title>
        <button
          type="button"
          phx-click="start_over"
          class="text-sm font-semibold text-slate-600 hover:text-brand-700 dark:text-slate-400 dark:hover:text-brand-300"
        >
          {gettext("Analyse another file")}
        </button>
      </div>

      <p :if={@found == 0} class="mt-2 text-sm text-slate-600 dark:text-slate-400">
        {gettext(
          "None of your contacts is here yet. Or they are, but keep their address private and have not linked their LinkedIn profile. Nothing was stored, and you can try again with a newer archive at any time."
        )}
      </p>

      <div :if={@found > 0}>
        <p class="mt-2 text-sm text-slate-600 dark:text-slate-400">
          {ngettext(
            "One of your LinkedIn contacts is already a vutuv member.",
            "%{formatted} of your LinkedIn contacts are already vutuv members.",
            @found,
            formatted: delimited_count(@found)
          )}
        </p>

        <%!-- Search + filter. Both narrow the same list the selection and the
        pager work on, so "select all" always means "all of what I am
        looking at". --%>
        <div class="mt-4 flex flex-wrap items-center gap-2">
          <form phx-change="search" class="min-w-0 flex-1">
            <label for="contact-search" class="sr-only">{gettext("Search by name")}</label>
            <input
              type="search"
              id="contact-search"
              name="q"
              value={@query}
              phx-debounce="200"
              placeholder={gettext("Search by name")}
              autocomplete="off"
              class={input_class()}
            />
          </form>
          <div class="flex rounded-lg bg-slate-100 p-1 dark:bg-slate-800">
            <.filter_tab value="new" active={@filter} label={gettext("Not following yet")} />
            <.filter_tab value="following" active={@filter} label={gettext("Following")} />
            <.filter_tab value="all" active={@filter} label={gettext("All")} />
          </div>
        </div>

        <%!-- The bulk bar. Nothing is preselected, so the primary button only
        appears once the member has picked somebody; "select all" carries its
        own number, because a button that follows several hundred people must
        say how many before it is pressed. --%>
        <div class="mt-3 flex flex-wrap items-center gap-x-4 gap-y-2 border-t border-slate-100 pt-3 text-sm dark:border-slate-800">
          <button
            :if={@selectable_count > 0}
            type="button"
            phx-click="select_all"
            class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
          >
            {gettext("Select all %{count}", count: delimited_count(@selectable_count))}
          </button>
          <button
            :if={@selected_count > 0}
            type="button"
            phx-click="select_none"
            class="font-semibold text-slate-600 hover:text-slate-800 dark:text-slate-400"
          >
            {gettext("Select none")}
          </button>
          <span :if={@selected_count > 0} class="text-slate-600 dark:text-slate-400">
            {ngettext("One selected", "%{formatted} selected", @selected_count,
              formatted: delimited_count(@selected_count)
            )}
          </span>
          <.button
            :if={@selected_count > 0}
            type="button"
            phx-click="follow_selected"
            phx-disable-with={gettext("Following…")}
            class="ml-auto"
          >
            {gettext("Follow selected")}
          </.button>
        </div>

        <%!-- Two ways to end up with an empty list, and they mean opposite
        things: nothing matched what you typed, or you already follow everybody
        the archive turned up — the ordinary outcome of running the same file
        twice, which must not read as a failed search. --%>
        <p :if={@total == 0} class="mt-4 text-sm text-slate-600 dark:text-slate-400">
          <%= if @query == "" and @filter == "new" do %>
            {gettext("You already follow every contact we found.")}
          <% else %>
            {gettext("Nobody here matches what you are looking for.")}
          <% end %>
        </p>

        <ul id="contact-matches" class="mt-4 divide-y divide-slate-100 dark:divide-slate-800">
          <.match_row
            :for={match <- @shown}
            match={match}
            user={@user}
            selected?={MapSet.member?(@selected, match.user.id)}
            follow_id={Map.get(@following_by_id, match.user.id)}
            work_line={Map.get(@work_info_by_id, match.user.id)}
          />
        </ul>

        <p :if={@total > @per_page} class="mt-4 text-xs text-slate-600 dark:text-slate-400">
          {gettext("Showing %{first}-%{last} of %{total}.",
            first: delimited_count((@page - 1) * @per_page + 1),
            last: delimited_count(min(@page * @per_page, @total)),
            total: delimited_count(@total)
          )}
        </p>
        <.page_nav page={@page} total_pages={@total_pages} />
      </div>
    </.card>
    """
  end

  attr(:value, :string, required: true)
  attr(:active, :string, required: true)
  attr(:label, :string, required: true)

  defp filter_tab(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="filter"
      phx-value-filter={@value}
      aria-pressed={to_string(@value == @active)}
      class={[
        "rounded-md px-3 py-1 text-sm font-medium",
        if(@value == @active,
          do: "bg-white text-slate-900 shadow-sm dark:bg-slate-900 dark:text-white",
          else: "text-slate-600 hover:text-slate-900 dark:text-slate-400 dark:hover:text-white"
        )
      ]}
    >
      {@label}
    </button>
    """
  end

  attr(:match, :map, required: true)
  attr(:user, :any, required: true)
  attr(:selected?, :boolean, required: true)
  attr(:follow_id, :any, default: nil)
  attr(:work_line, :any, default: nil)

  defp match_row(assigns) do
    ~H"""
    <li class="flex items-center gap-3 py-3">
      <%!-- Already following? Then there is nothing to select: the checkbox
      would offer an act that cannot happen, so the row shows its state and
      the pill (which can still unfollow) instead. --%>
      <input
        :if={is_nil(@follow_id)}
        type="checkbox"
        id={"select-#{@match.user.id}"}
        checked={@selected?}
        phx-click="toggle"
        phx-value-id={@match.user.id}
        class={checkbox_class()}
      />
      <span :if={@follow_id} class="w-4 shrink-0" aria-hidden="true"></span>
      <.link navigate={~p"/#{@match.user}"} class="shrink-0">
        <.avatar user={@match.user} size="sm" alt={UserHelpers.full_name(@match.user)} />
      </.link>
      <div class="min-w-0 flex-1 text-sm">
        <.link
          navigate={~p"/#{@match.user}"}
          class="block truncate font-medium text-slate-800 hover:text-brand-700 dark:hover:text-brand-300 dark:text-slate-100"
        >
          {UserHelpers.full_name(@match.user)}
        </.link>
        <p :if={@work_line} class="mb-0 truncate text-sm text-slate-600 dark:text-slate-400">
          {@work_line}
        </p>
        <p class="mb-0 truncate text-xs text-slate-500 dark:text-slate-500">{evidence(@match.via)}</p>
      </div>
      <.follow_button
        variant="text"
        follower_id={@user.id}
        followee_id={@match.user.id}
        follow_id={@follow_id}
        live?
      />
    </li>
    """
  end

  # Why this person is on the list, in the row rather than in a legend: a
  # grouped list would say it once at the top and be scrolled away by row 40.
  defp evidence(:email), do: gettext("Same email address as your contact")
  defp evidence(:linkedin), do: gettext("Links the same LinkedIn profile")

  attr(:page, :integer, required: true)
  attr(:total_pages, :integer, required: true)

  defp page_nav(assigns) do
    assigns =
      assign(
        assigns,
        :window,
        Enum.filter((assigns.page - 3)..(assigns.page + 3), &(&1 in 1..assigns.total_pages))
      )

    ~H"""
    <nav
      :if={@total_pages > 1}
      aria-label={gettext("Pagination")}
      class="mt-4 flex flex-wrap items-center justify-center gap-1 text-sm font-semibold"
    >
      <%!-- Paging is phx-click rather than a `?page=` link on purpose: this
      list comes from a file on the member's own disk, so a page URL would look
      shareable and reloadable while being neither. --%>
      <.page_button :if={List.first(@window) > 1} page={1} current={@page} />
      <span :if={List.first(@window) > 2} class="px-1 text-slate-600 dark:text-slate-400">…</span>
      <.page_button :for={number <- @window} page={number} current={@page} />
      <span :if={List.last(@window) < @total_pages - 1} class="px-1 text-slate-600 dark:text-slate-400">
        …
      </span>
      <.page_button
        :if={List.last(@window) < @total_pages}
        page={@total_pages}
        current={@page}
      />
    </nav>
    """
  end

  attr(:page, :integer, required: true)
  attr(:current, :integer, required: true)

  defp page_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="page"
      phx-value-page={@page}
      aria-current={if(@page == @current, do: "page")}
      class={[
        "flex h-9 min-w-9 items-center justify-center rounded-lg px-2",
        if(@page == @current,
          do: "bg-brand-600 text-white",
          else: "text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-800"
        )
      ]}
    >
      {@page}
    </button>
    """
  end

  defp upload_error_message(:too_large),
    do: gettext("This file is too large. Please choose a ZIP of at most 50 MB.")

  defp upload_error_message(:not_accepted), do: gettext("Please choose a ZIP file.")
  defp upload_error_message(_error), do: gettext("That file could not be read.")
end
