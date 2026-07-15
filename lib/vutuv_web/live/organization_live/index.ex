defmodule VutuvWeb.OrganizationLive.Index do
  @moduledoc """
  The public directory of verified organization pages (`/organizations`, issue #929).
  Embedded via `live_render` from `VutuvWeb.OrganizationController` (off-router, like
  the profile), so the agent-format siblings stay controller-owned. Search is
  live (`phx-change`, socket state); pagination is real `<.link navigate>`
  anchors carrying the current search, so every active page is reachable by
  following links alone (the crawl path).
  """

  use VutuvWeb, :live_view

  import VutuvWeb.OrganizationComponents

  alias Vutuv.Organizations
  alias Vutuv.Pages
  alias VutuvWeb.Live.InitAssigns

  # Embedded via live_render (off-router), so the URL query is not available as
  # mount params — the controller forwards `q` / `page` through the session.
  @impl true
  def mount(_params, session, socket) do
    socket = InitAssigns.assign_embedded(socket, session)

    search = clean(session["q"])

    socket =
      socket
      |> assign(:page_title, gettext("Organizations"))
      |> assign(:search, search || "")
      |> load(search, Pages.page_param(session))

    {:ok, socket}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:search, q) |> load(clean(q), 1)}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket, search, page) do
    assign(socket, :result, Organizations.directory_page(search: search, page: page))
  end

  defp clean(nil), do: nil

  defp clean(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # Real anchors carrying the current search so pagination is link-walk crawlable.
  defp page_path(search, page) do
    query = if(search in [nil, ""], do: [], else: [{"q", search}]) ++ [{"page", page}]
    ~p"/organizations?#{query}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6">
      <div class="mb-6 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">{gettext("Organizations")}</h1>
          <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
            {gettext("Verified pages for companies, associations, schools, public authorities and other groups, not for single people. Every page has a proven web domain, so you know it is really them.")}
          </p>
        </div>
        <.link
          navigate={~p"/organizations/new"}
          class="rounded-lg bg-brand-600 px-4 py-2 text-center text-sm font-semibold text-white hover:bg-brand-700"
        >
          {gettext("Add your organization")}
        </.link>
      </div>

      <form phx-change="search" phx-submit="search" class="mb-6">
        <label for="organization-search" class="sr-only">{gettext("Search organizations")}</label>
        <input
          type="search"
          name="q"
          id="organization-search"
          value={@search}
          autocomplete="off"
          phx-debounce="200"
          placeholder={gettext("Search by name or city")}
          class={input_class()}
        />
      </form>

      <%= if @result.entries == [] do %>
        <.card class="text-center">
          <p class="text-slate-600 dark:text-slate-400">
            <%= if @search in [nil, ""] do %>
              {gettext("No organization pages yet. Be the first to add yours.")}
            <% else %>
              {gettext("No organizations found for %{term}.", term: @search)}
            <% end %>
          </p>
          <.link
            navigate={~p"/organizations/new"}
            class="mt-4 inline-block text-sm font-semibold text-brand-600 hover:text-brand-700"
          >
            {gettext("Add your organization")}
          </.link>
        </.card>
      <% else %>
        <div id="organization-directory" class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <.link
            :for={organization <- @result.entries}
            navigate={~p"/organizations/#{organization.slug}"}
            class="flex items-center gap-4 rounded-2xl bg-white p-4 shadow-sm ring-1 ring-slate-200 transition hover:ring-brand-300 dark:bg-slate-900 dark:ring-slate-800"
          >
            <.organization_logo organization={organization} class="h-14 w-14 shrink-0" />
            <div class="min-w-0">
              <p class="truncate font-semibold text-slate-900 dark:text-slate-100">{organization.name}</p>
              <.organization_location organization={organization} class="truncate text-sm text-slate-600 dark:text-slate-400" />
              <.kind_badge kind={organization.kind} class="mt-1" />
            </div>
          </.link>
        </div>

        <nav
          :if={@result.total_pages > 1}
          aria-label={gettext("Pagination")}
          class="mt-8 flex flex-wrap justify-center gap-1"
        >
          <.link
            :for={page <- 1..@result.total_pages}
            navigate={page_path(@search, page)}
            aria-current={page == @result.page && "page"}
            class={[
              "rounded-lg px-3 py-1.5 text-sm font-semibold",
              if(page == @result.page,
                do: "bg-brand-600 text-white",
                else: "bg-slate-100 text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
              )
            ]}
          >
            {page}
          </.link>
        </nav>
      <% end %>
    </div>
    """
  end
end
