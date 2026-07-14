defmodule VutuvWeb.SearchLive do
  @moduledoc """
  Search-as-you-type. Results stream in once the query reaches three letters
  (`Vutuv.Search.instant/2`) and narrow with every keystroke; `?q=` (plus the
  `scope` and `exact` filters) is kept in sync via `push_patch` so a search
  stays shareable and reloadable. Exact name matches and phonetically similar
  ones render as clearly separated groups.

  Filters: scope chips (all / people / tags / posts) and an "exact matches
  only" toggle. Power users get operators instead, parsed by
  `Vutuv.Search.parse/2`: `vorname:`/`nachname:` (aliases `first:`/`last:`),
  `@handle`, double quotes for exact-only, and the combinable people filters
  `tag:`/`skill:` (has the tag) and `ort:`/`stadt:`/`city:` (has an address
  in the city) - "müller tag:php", "müller ort:koblenz".

  A query is recorded for the search history only after it settles (no
  keystroke for two seconds), so typing "meier" stores one query, not five.
  """
  use VutuvWeb, :live_view

  import VutuvWeb.SavedSearchComponents

  alias Vutuv.SavedSearches
  alias Vutuv.Search
  alias VutuvWeb.UserHelpers
  alias VutuvWeb.UserHTML

  @record_after :timer.seconds(2)

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns[:current_user]

    {:ok,
     socket
     |> assign(:page_title, gettext("Search"))
     |> assign(:current_user_id, current_user && current_user.id)
     |> assign(:show_save?, false)
     |> assign(:saved?, false)
     |> assign(:record_timer, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    q = params["q"] || ""
    scope = parse_scope(params["scope"])
    exact = params["exact"] == "1"
    results = Search.instant(q, scope: scope, exact: exact, viewer: socket.assigns[:current_user])

    {:noreply,
     socket
     |> assign(:q, q)
     |> assign(:scope, scope)
     |> assign(:exact, exact)
     # A new query invalidates any open/confirmed save panel.
     |> assign(:show_save?, false)
     |> assign(:saved?, false)
     |> assign(:saveable?, saveable?(results))
     # Operators in the query override the scope chips; highlight what the
     # search actually did and disable the chips that can do nothing (#846).
     |> assign(:effective_scope, (results && results.parsed.scope) || scope)
     |> assign(:scope_pinned?, (results && results.parsed.scope_pinned?) || false)
     |> assign(:results, results)
     |> assign_needles(results)
     |> assign_people_maps(results)
     |> schedule_record(results)}
  end

  # What `highlight/2` marks per section. Exact people carry a literal
  # substring of the query in their name; similar (phonetic) matches do not,
  # so they deliberately stay unmarked. Slug and email matches are not part
  # of the rendered name either.
  defp assign_needles(socket, nil) do
    assign(socket, people_needles: [], tag_needle: nil, post_needles: [])
  end

  defp assign_needles(socket, %{parsed: parsed}) do
    people_needles =
      cond do
        parsed.slug -> []
        parsed.first_name || parsed.last_name -> [parsed.first_name, parsed.last_name]
        Search.email?(parsed.text) -> []
        true -> [parsed.text]
      end

    assign(socket,
      people_needles: people_needles,
      tag_needle: parsed.text,
      post_needles: String.split(parsed.text)
    )
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply,
     push_patch(socket,
       to: search_path(q, socket.assigns.scope, socket.assigns.exact),
       replace: true
     )}
  end

  def handle_event("toggle_save_search", _params, socket),
    do: {:noreply, update(socket, :show_save?, &(not &1))}

  def handle_event("save_search", %{"notify" => notify}, socket),
    do: {:noreply, save_current_search(socket, notify)}

  # Only a people search with a structured operator (tag:/ort:/status:) is worth
  # saving as an alert — a bare free-text or name search never triggers a
  # people alert (issue #935), so the button stays hidden for it.
  defp saveable?(%{parsed: parsed}), do: !!(parsed.tag || parsed.city || parsed.status)
  defp saveable?(_results), do: false

  defp save_current_search(%{assigns: %{current_user: nil}} = socket, _notify),
    do: push_navigate(socket, to: ~p"/login")

  defp save_current_search(socket, notify) do
    query = search_query(socket.assigns.q, socket.assigns.scope, socket.assigns.exact)

    case SavedSearches.create(socket.assigns.current_user, %{
           kind: :people,
           query: query,
           notify: notify
         }) do
      {:ok, _} ->
        socket
        |> assign(saved?: true, show_save?: false)
        |> put_flash(:info, gettext("Search saved."))

      {:error, :quota} ->
        put_flash(
          socket,
          :error,
          gettext("You already have the maximum number of saved searches.")
        )

      {:error, _} ->
        put_flash(socket, :error, gettext("That did not work."))
    end
  end

  # The stored query string mirrors the /search URL (q + non-default scope +
  # exact), so the sweeper and the "run now" link replay the same search.
  defp search_query(q, scope, exact) do
    [q: q, scope: scope != :all && scope, exact: exact && "1"]
    |> Enum.reject(fn {_k, v} -> v in ["", false, nil] end)
    |> URI.encode_query()
  end

  # The settle timer fired: this query stopped changing, so it counts.
  @impl true
  def handle_info({:record_query, q}, socket) do
    Search.record_query(q, socket.assigns[:current_user])
    {:noreply, socket}
  end

  @scopes ~w(all people tags posts)

  defp parse_scope(scope) when scope in @scopes, do: String.to_existing_atom(scope)
  defp parse_scope(_scope), do: :all

  # The canonical /search URL for a query + filter combination; defaults stay
  # out of the query string so plain searches keep plain URLs.
  defp search_path(q, scope, exact) do
    params =
      Enum.reject(
        [q: q, scope: scope != :all && scope, exact: exact && "1"],
        fn {_k, v} -> v in ["", false, nil] end
      )

    if params == [], do: ~p"/search", else: ~p"/search?#{params}"
  end

  # The page-wide maps `UserHTML.user_row/1` expects, built once per query
  # (one query each) instead of per row.
  defp assign_people_maps(socket, nil) do
    assign(socket, work_info_by_id: %{}, following_by_id: %{})
  end

  defp assign_people_maps(socket, results) do
    people = results.exact_people ++ results.similar_people

    assign(socket,
      work_info_by_id: UserHelpers.work_information_map(people, 45),
      following_by_id: UserHelpers.following_map(socket.assigns[:current_user], people)
    )
  end

  # Debounce the history write past the typing: every new query cancels the
  # previous timer, so only a query that survives the settle window is stored.
  defp schedule_record(socket, results) do
    if timer = socket.assigns.record_timer, do: Process.cancel_timer(timer)

    timer =
      if results && connected?(socket) do
        Process.send_after(self(), {:record_query, results.query}, @record_after)
      end

    assign(socket, :record_timer, timer)
  end

  defp scope_label(:all), do: gettext("All")
  defp scope_label(:people), do: gettext("People")
  defp scope_label(:tags), do: gettext("Tags")
  defp scope_label(:posts), do: gettext("Posts")

  attr(:id, :string, required: true)
  attr(:patch, :string, required: true)
  attr(:active, :boolean, required: true)
  attr(:disabled, :boolean, default: false)
  attr(:title, :string, default: nil)
  slot(:inner_block, required: true)

  # A disabled chip is a static span: with a people operator in the query the
  # scope is pinned, so a link that changes nothing would just look broken
  # (#846).
  defp filter_chip(%{disabled: true} = assigns) do
    ~H"""
    <span
      id={@id}
      aria-disabled="true"
      title={@title}
      class="cursor-not-allowed rounded-full bg-slate-100 px-3 py-1.5 text-sm font-semibold text-slate-600 opacity-40 dark:bg-slate-800 dark:text-slate-300"
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp filter_chip(assigns) do
    ~H"""
    <.link
      id={@id}
      patch={@patch}
      class={[
        "rounded-full px-3 py-1.5 text-sm font-semibold transition-colors",
        if(@active,
          do: "bg-brand-600 text-white",
          else:
            "bg-slate-100 text-slate-600 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-300 dark:hover:bg-slate-700"
        )
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- One centered column (classic search page layout): on wide screens a
    left-pinned narrow column leaves the right half of the canvas dead. --%>
    <div id="search" class="mx-auto max-w-2xl py-8">
      <h1 class="text-2xl font-bold text-slate-800 dark:text-slate-100">{gettext("Search")}</h1>

      <form id="search-form" phx-change="search" phx-submit="search" class="mt-4">
        <input
          type="search"
          name="q"
          value={@q}
          placeholder={gettext("Search for people, tags, or posts")}
          autocomplete="off"
          autofocus
          phx-debounce="250"
          class={[input_class(), "text-base"]}
        />
      </form>

      <div id="search-filters" class="mt-3 flex flex-wrap items-center gap-2">
        <.filter_chip
          :for={scope <- [:all, :people, :tags, :posts]}
          id={"search-scope-#{scope}"}
          patch={search_path(@q, scope, @exact)}
          active={@effective_scope == scope}
          disabled={@scope_pinned? and scope != :people}
          title={gettext("Not available while the search uses a people filter.")}
        >
          {scope_label(scope)}
        </.filter_chip>

        <span class="mx-1 hidden h-5 w-px bg-slate-200 sm:block dark:bg-slate-700"></span>

        <.filter_chip id="search-exact-toggle" patch={search_path(@q, @scope, !@exact)} active={@exact}>
          <span :if={@exact}>✓ </span>{gettext("Exact matches only")}
        </.filter_chip>
      </div>

      <p
        :if={@scope_pinned?}
        id="search-scope-pinned-hint"
        class="mt-2 text-xs text-slate-600 dark:text-slate-400"
      >
        {gettext("Your search uses a people filter such as tag: or city:, so it only finds people.")}
      </p>

      <p
        :if={@results == nil and String.trim(@q) != ""}
        id="search-hint"
        class="mt-3 text-sm text-slate-600 dark:text-slate-400"
      >
        {gettext("Results appear once you have typed at least three letters.")}
      </p>

      <.card :if={@q == ""} class="mt-6">
        <.section_title>{gettext("Search Tips")}</.section_title>
        <p class="mt-3 text-sm text-slate-600 dark:text-slate-300">
          {gettext("You can search for a name, email, or tag, or for words in public posts.")}
        </p>
        <p class="mt-2 text-sm text-slate-600 dark:text-slate-300">
          {gettext("Our search will try to match similar names to your search, so don't worry about spelling.")}
        </p>
        <%!-- m-0 / font-normal undo the legacy `dl dt`/`dl dd` element
        defaults from components.css so the grid rows line up. The operator
        examples are gettext'd too: every operator has a German and an English
        key (both always work), so each locale shows its own spelling. --%>
        <dl id="search-syntax" class="mt-4 grid gap-x-6 gap-y-2 text-sm sm:grid-cols-[auto_1fr]">
          <dt class="m-0 font-mono text-slate-700 dark:text-slate-200">{gettext("first:stefan")}</dt>
          <dd class="m-0 font-normal text-slate-600 dark:text-slate-400">{gettext("searches first names only (last: for last names)")}</dd>
          <dt class="m-0 font-mono text-slate-700 dark:text-slate-200">tag:php</dt>
          <dd class="m-0 font-normal text-slate-600 dark:text-slate-400">{gettext("only people with this tag, combinable: miller tag:php")}</dd>
          <dt class="m-0 font-mono text-slate-700 dark:text-slate-200">{gettext("city:koblenz")}</dt>
          <dd class="m-0 font-normal text-slate-600 dark:text-slate-400">{gettext("only people with an address in this city")}</dd>
          <dt class="m-0 font-mono text-slate-700 dark:text-slate-200">status:looking</dt>
          <dd class="m-0 font-normal text-slate-600 dark:text-slate-400">{gettext("only people open to offers (status:open) or looking (status:looking)")}</dd>
          <dt class="m-0 font-mono text-slate-700 dark:text-slate-200">@stefan</dt>
          <dd class="m-0 font-normal text-slate-600 dark:text-slate-400">{gettext("searches usernames")}</dd>
          <dt class="m-0 font-mono text-slate-700 dark:text-slate-200">"{gettext("miller")}"</dt>
          <dd class="m-0 font-normal text-slate-600 dark:text-slate-400">{gettext("in quotes: exact matches only, no similar names")}</dd>
        </dl>
      </.card>

      <div :if={@results} class="mt-6 space-y-6">
        <.save_search_control
          :if={@current_user && @saveable?}
          id="people-save-search"
          show?={@show_save?}
          saved?={@saved?}
        />

        <.card :if={@results.exact_people != [] or @results.similar_people != []} id="search-people">
          <.section_title>
            {gettext("People")} ({compact_count(length(@results.exact_people) + length(@results.similar_people))})
          </.section_title>

          <ul :if={@results.exact_people != []} id="search-people-exact" class="mt-4 space-y-4">
            <UserHTML.user_row
              :for={user <- @results.exact_people}
              user={user}
              current_user={@current_user}
              current_user_id={@current_user_id}
              work_info_by_id={@work_info_by_id}
              following_by_id={@following_by_id}
              highlight={@people_needles}
            />
          </ul>

          <div
            :if={@results.similar_people != []}
            id="search-people-similar"
            class={[
              "mt-5",
              @results.exact_people != [] && "border-t border-slate-100 pt-4 dark:border-slate-800"
            ]}
          >
            <h3 class="text-sm font-semibold text-slate-600 dark:text-slate-400">
              {gettext("Similar names")}
            </h3>
            <p class="mt-0.5 text-xs text-slate-600 dark:text-slate-400">
              {gettext("Not an exact match, but sounds like your search.")}
            </p>
            <ul class="mt-3 space-y-4">
              <UserHTML.user_row
                :for={user <- @results.similar_people}
                user={user}
                current_user={@current_user}
                current_user_id={@current_user_id}
                work_info_by_id={@work_info_by_id}
                following_by_id={@following_by_id}
              />
            </ul>
          </div>
        </.card>

        <.card :if={@results.tags != []} id="search-tags">
          <.section_title>
            {gettext("Tags")} ({compact_count(length(@results.tags))})
          </.section_title>
          <div class="mt-4 flex flex-wrap gap-2">
            <.chip :for={tag <- @results.tags} navigate={~p"/tags/#{tag}"}>
              {highlight(tag.name, @tag_needle)}<span
                :if={Map.get(@results.tag_member_counts, tag.id, 0) > 0}
                class="font-normal"
              > · {compact_count(@results.tag_member_counts[tag.id])}</span>
            </.chip>
          </div>
        </.card>

        <.card :if={@results.posts != []} id="search-posts">
          <.section_title>
            {gettext("Posts")} ({compact_count(length(@results.posts))})
          </.section_title>
          <ul class="mt-4 divide-y divide-slate-100 dark:divide-slate-800">
            <li :for={post <- @results.posts} class="flex items-start gap-3 py-4 first:pt-0 last:pb-0">
              <.avatar user={post.user} size="sm" shape="circle" presence />
              <div class="min-w-0">
                <p class="mb-0 text-sm">
                  <.link
                    href={~p"/#{post.user}"}
                    class="font-medium text-slate-800 hover:text-brand-700 dark:text-slate-100"
                  >
                    {UserHelpers.full_name(post.user)}
                  </.link>
                  <span class="text-slate-600 dark:text-slate-400">@{post.user.username}</span>
                  <span class="text-slate-600 dark:text-slate-400">· {post.published_on}</span>
                </p>
                <.link
                  href={~p"/#{post.user}/posts/#{post.id}"}
                  class="mt-1 block truncate text-sm text-slate-700 hover:text-brand-700 dark:text-slate-300"
                >
                  {highlight(VutuvWeb.AgentDocs.excerpt(post.body), @post_needles)}
                </.link>
              </div>
            </li>
          </ul>
        </.card>

        <.card :if={
          @results.exact_people == [] and @results.similar_people == [] and
            @results.tags == [] and @results.posts == []
        }>
          <p id="search-empty" class="mb-0 text-center font-semibold text-slate-600 dark:text-slate-400">
            {gettext("No results for \"%{query}\"", query: @results.query)}
          </p>
        </.card>
      </div>
    </div>
    """
  end
end
