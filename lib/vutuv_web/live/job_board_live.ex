defmodule VutuvWeb.JobBoardLive do
  @moduledoc """
  The public job board (`/jobs`, issue #933): a filterable, keyset-paginated,
  live-updating list of every published posting the current viewer may see.

  Embedded via `live_render` from `VutuvWeb.JobPostingController.index` (off the
  `live_session`, like the profile / feed / organization pages) so the
  controller can negotiate the agent-format siblings (`/jobs.md` …). Because it
  is off-router it cannot use `push_patch`; instead **filter state lives
  entirely in the URL** — the search form is a plain GET and every chip / next
  link is a real `<a href>`, so the board is shareable and link-walk crawlable.
  Each filter change reloads the page (a fresh mount from the new URL); PubSub
  (`Vutuv.Jobs` "jobs" topic) keeps an open page live as postings are published,
  expire or are frozen, and the per-card like / bookmark toggles run in-process.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.JobComponents
  import VutuvWeb.SavedSearchComponents

  alias Vutuv.Countries
  alias Vutuv.Geo
  alias Vutuv.Jobs
  alias Vutuv.Jobs.JobPosting
  alias Vutuv.Salary
  alias VutuvWeb.ApiV2
  alias VutuvWeb.Live.InitAssigns

  @impl true
  def mount(_params, session, socket) do
    socket = InitAssigns.assign_embedded(socket, session)
    user = socket.assigns.current_user

    if connected?(socket), do: Jobs.subscribe_board()

    raw = session["params"] || %{}

    {:ok,
     socket
     |> assign(:page_title, gettext("Jobs"))
     |> assign(:params, link_params(raw))
     |> assign(:filters, Jobs.board_filters(raw, user))
     |> assign(:cursor, decode_cursor(raw["cursor"]))
     |> assign(:has_salary_expectation?, Jobs.desired_salary_floor(user) != nil)
     |> assign(:viewer_tags, Jobs.viewer_tag_slugs(user))
     |> assign(:show_save?, false)
     |> assign(:saved?, false)
     |> load_board()}
  end

  defp load_board(socket) do
    %{filters: filters, current_user: user, cursor: cursor} = socket.assigns
    page = Jobs.board_page(user, filters, cursor: cursor)

    socket
    |> assign(:postings, page.entries)
    |> assign(:engagement, Jobs.board_engagement_map(page.entries, user))
    |> assign(:more?, page.more?)
    |> assign(:next_cursor, page.cursor && ApiV2.encode_cursor(page.cursor))
  end

  # --- events ---------------------------------------------------------------

  @impl true
  def handle_event("toggle_like", %{"id" => id}, socket),
    do: {:noreply, toggle(socket, id, :like)}

  def handle_event("toggle_bookmark", %{"id" => id}, socket),
    do: {:noreply, toggle(socket, id, :bookmark)}

  def handle_event("toggle_save_search", _params, socket),
    do: {:noreply, update(socket, :show_save?, &(not &1))}

  def handle_event("save_search", %{"notify" => notify}, socket),
    do: {:noreply, save_current_search(socket, notify)}

  defp toggle(%{assigns: %{current_user: nil}} = socket, _id, _kind),
    do: push_navigate(socket, to: ~p"/login")

  defp toggle(socket, id, kind) do
    case Enum.find(socket.assigns.postings, &(&1.id == id)) do
      nil ->
        socket

      posting ->
        user = socket.assigns.current_user
        Jobs.toggle_engagement(kind, user, posting, socket.assigns.engagement[id])
        fresh = Jobs.job_posting_engagement(posting, user)
        assign(socket, :engagement, Map.put(socket.assigns.engagement, id, fresh))
    end
  end

  # Store the board's current filter set (the shareable link params, which
  # already drop the page cursor and blanks) as a saved jobs search. A
  # `salary_min=mine` filter is kept verbatim, so it resolves against the
  # member's live expectation at sweep time and the private figure is never
  # written into the query column (issue #935).
  defp save_current_search(socket, notify),
    do: save_search(socket, :jobs, URI.encode_query(socket.assigns.params), notify)

  @impl true
  def handle_info(:jobs_board_changed, socket), do: {:noreply, load_board(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- filter parsing -------------------------------------------------------

  # Raw params → the atom-keyed filter map lives in `Vutuv.Jobs.board_filters/2`
  # (shared verbatim with the saved-search sweeper). The board only builds the
  # shareable link params and decodes the keyset cursor.

  # The URL params that build the shareable filter links: everything present
  # except the page cursor (a filter change resets to page one) and blanks.
  defp link_params(raw) do
    raw
    |> Map.drop(["cursor"])
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp decode_cursor(value) do
    case ApiV2.decode_cursor(value) do
      {:ok, {%NaiveDateTime{}, _id} = cursor} -> cursor
      _ -> nil
    end
  end

  # --- link building --------------------------------------------------------

  # Toggle a chip param: set it, or drop it when it already holds this value.
  defp toggle_param(params, key, value) do
    if params[key] == value, do: Map.delete(params, key), else: Map.put(params, key, value)
  end

  defp active?(params, key, value), do: params[key] == value
  defp any_filters?(params), do: params != %{}

  # --- render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6">
      <div class="mb-4 flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">{gettext("Jobs")}</h1>
          <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
            {gettext("Open positions on vutuv, newest first.")}
          </p>
        </div>
        <.link
          :if={@current_user}
          navigate={~p"/jobs/new"}
          class="rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white hover:bg-brand-700"
        >
          {gettext("Post a job")}
        </.link>
      </div>

      <.search_form params={@params} filters={@filters} />

      <div id="job-filter-chips" class="mt-3 -mx-4 flex gap-2 overflow-x-auto px-4 pb-1 [scrollbar-width:none]">
        <.link
          :for={type <- [:onsite, :hybrid, :remote]}
          navigate={~p"/jobs?#{toggle_param(@params, "workplace", Atom.to_string(type))}"}
          class={chip_class(active?(@params, "workplace", Atom.to_string(type)))}
        >
          {JobPosting.workplace_type_label(type)}
        </.link>

        <.link
          :if={@current_user}
          navigate={~p"/jobs?#{toggle_param(@params, "my_tags", "1")}"}
          class={chip_class(active?(@params, "my_tags", "1"))}
        >
          {gettext("Matches my tags")}
        </.link>

        <.link
          :if={@current_user && @has_salary_expectation?}
          navigate={~p"/jobs?#{toggle_param(@params, "salary_min", "mine")}"}
          class={chip_class(active?(@params, "salary_min", "mine"))}
        >
          {gettext("From my salary expectation")}
        </.link>

        <.link
          :if={any_filters?(@params)}
          navigate={~p"/jobs"}
          class="whitespace-nowrap rounded-full px-3 py-1.5 text-sm font-semibold text-slate-600 underline decoration-dotted hover:text-slate-800 dark:text-slate-400"
        >
          {gettext("Clear filters")}
        </.link>
      </div>

      <.save_search_control
        :if={@current_user && any_filters?(@params)}
        id="jobs-save-search"
        show?={@show_save?}
        saved?={@saved?}
        class="mt-3"
      />

      <p :if={@params["tag"]} class="mt-3 text-sm text-slate-600 dark:text-slate-400">
        {gettext("Tag")}:
        <.link
          navigate={~p"/jobs?#{Map.delete(@params, "tag")}"}
          class="inline-flex items-center gap-1 rounded-lg bg-brand-50 px-2.5 py-1 font-medium text-brand-700 dark:bg-brand-900/40 dark:text-brand-100"
        >
          {@params["tag"]} <span aria-hidden="true">✕</span>
        </.link>
      </p>

      <div :if={@postings == []} class="mt-6 rounded-2xl bg-white p-8 text-center shadow-sm ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800">
        <p class="text-sm text-slate-600 dark:text-slate-400">{empty_line(@params)}</p>
        <.link
          :if={not any_filters?(@params) && @current_user}
          navigate={~p"/jobs/new"}
          class="mt-3 inline-block text-sm font-semibold text-brand-600 hover:text-brand-700"
        >
          {gettext("Post the first one")}
        </.link>
      </div>

      <div class="mt-6 grid gap-4 sm:grid-cols-2">
        <.job_card
          :for={posting <- @postings}
          posting={posting}
          viewer_tags={@viewer_tags}
          engagement={@engagement[posting.id]}
        />
      </div>

      <div :if={@more?} class="mt-6 text-center">
        <.link
          navigate={~p"/jobs?#{Map.put(@params, "cursor", @next_cursor)}"}
          class="inline-block rounded-lg bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
        >
          {gettext("More jobs")}
        </.link>
      </div>
    </div>
    """
  end

  attr(:params, :map, required: true)
  attr(:filters, :map, required: true)

  defp search_form(assigns) do
    ~H"""
    <form method="get" action={~p"/jobs"} class="grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
      <input
        type="search"
        name="q"
        value={@params["q"]}
        placeholder={gettext("Search jobs")}
        class={[input_class(), "lg:col-span-2"]}
      />

      <input
        type="text"
        name="near"
        value={@params["near"]}
        placeholder={gettext("City or zip code")}
        class={input_class()}
      />

      <select name="radius" class={input_class()} aria-label={gettext("Radius")}>
        <option :for={{label, km} <- radius_options()} value={km} selected={to_string(km) == @params["radius"]}>
          {label}
        </option>
      </select>

      <select name="country" class={input_class()} aria-label={gettext("Country")}>
        <option value="">{gettext("All countries")}</option>
        <option :for={code <- Geo.geo_countries()} value={code} selected={code == @params["country"]}>
          {Countries.name(code)}
        </option>
      </select>

      <select name="employment" class={input_class()} aria-label={gettext("Employment type")}>
        <option value="">{gettext("Any employment type")}</option>
        <option
          :for={{label, type} <- JobPosting.employment_type_options()}
          value={type}
          selected={Atom.to_string(type) == @params["employment"]}
        >
          {label}
        </option>
      </select>

      <%!-- Free minimum-salary filter, open to everyone (issue #953). While the
            "from my expectation" chip drives it, the field is disabled and a
            hidden `mine` token rides along, so the member's private figure is
            never seeded into it or submitted (issue #935). --%>
      <input
        type="number"
        name="salary_min"
        id="job-salary-min"
        min="1"
        step="1000"
        inputmode="numeric"
        value={salary_field_value(@params)}
        disabled={@params["salary_min"] == "mine"}
        placeholder={salary_placeholder()}
        aria-label={gettext("Minimum yearly salary")}
        class={[input_class(), "disabled:cursor-not-allowed disabled:opacity-60"]}
      />

      <button
        type="submit"
        class="rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white hover:bg-brand-700"
      >
        {gettext("Search")}
      </button>

      <%!-- Chip-driven filters ride along so a search submit keeps them. --%>
      <input :if={@params["workplace"]} type="hidden" name="workplace" value={@params["workplace"]} />
      <input :if={@params["tag"]} type="hidden" name="tag" value={@params["tag"]} />
      <input :if={@params["my_tags"]} type="hidden" name="my_tags" value={@params["my_tags"]} />
      <%!-- The visible number field owns a typed `salary_min`; only the "mine"
            token needs a hidden carrier (its field is disabled, so it can't). --%>
      <input :if={@params["salary_min"] == "mine"} type="hidden" name="salary_min" value="mine" />
    </form>
    """
  end

  # The number field's value: a typed `salary_min`, but never the `mine` token
  # (which stands in for the member's private expectation — issue #935) and
  # empty by default, so the field starts blank for a logged-out visitor or a
  # member without an expectation (issue #953).
  defp salary_field_value(%{"salary_min" => "mine"}), do: nil
  defp salary_field_value(%{"salary_min" => value}), do: value
  defp salary_field_value(_params), do: nil

  defp salary_placeholder do
    gettext("Min. salary/year (%{currency})",
      currency: Salary.currency_symbol(Jobs.default_currency())
    )
  end

  defp chip_class(active?) do
    [
      "whitespace-nowrap rounded-full px-3 py-1.5 text-sm font-semibold transition-colors",
      if(active?,
        do: "bg-brand-600 text-white",
        else:
          "bg-slate-100 text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
      )
    ]
  end

  defp radius_options do
    for km <- Jobs.board_radii() do
      if km == 0, do: {gettext("Exact"), 0}, else: {gettext("%{km} km", km: km), km}
    end
  end

  defp empty_line(params) do
    if any_filters?(params) do
      gettext("No matching positions. Try adjusting the filters.")
    else
      gettext("No job postings yet.")
    end
  end
end
