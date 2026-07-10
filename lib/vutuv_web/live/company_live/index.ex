defmodule VutuvWeb.CompanyLive.Index do
  @moduledoc """
  The public directory of verified company pages (`/companies`, issue #929).
  Embedded via `live_render` from `VutuvWeb.CompanyController` (off-router, like
  the profile), so the agent-format siblings stay controller-owned. Search is
  live (`phx-change`, socket state); pagination is real `<.link navigate>`
  anchors carrying the current search, so every active page is reachable by
  following links alone (the crawl path).
  """

  use VutuvWeb, :live_view

  import VutuvWeb.CompanyComponents

  alias Vutuv.Companies
  alias VutuvWeb.Live.InitAssigns

  # Embedded via live_render (off-router), so the URL query is not available as
  # mount params — the controller forwards `q` / `page` through the session.
  @impl true
  def mount(_params, session, socket) do
    current_user = InitAssigns.load_user(session["user_id"])
    VutuvWeb.LiveLocale.put_locale(current_user, session)

    search = clean(session["q"])

    socket =
      socket
      |> assign(:current_user, current_user)
      |> assign(:current_user_id, current_user && current_user.id)
      |> assign(:locale, session["locale"])
      |> assign(:shell_path, session["request_path"])
      |> assign(:page_title, gettext("Companies"))
      |> assign(:search, search || "")
      |> load(search, to_page(session["page"]))

    {:ok, socket}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:search, q) |> load(clean(q), 1)}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket, search, page) do
    assign(socket, :result, Companies.directory_page(search: search, page: page))
  end

  defp clean(nil), do: nil

  defp clean(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp to_page(nil), do: 1

  defp to_page(value) do
    case Integer.parse(value) do
      {page, _} when page > 0 -> page
      _ -> 1
    end
  end

  # Real anchors carrying the current search so pagination is link-walk crawlable.
  defp page_path(search, page) do
    query = if(search in [nil, ""], do: [], else: [{"q", search}]) ++ [{"page", page}]
    ~p"/companies?#{query}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="py-6">
      <div class="mb-6 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">{gettext("Companies")}</h1>
          <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
            {gettext("Verified company pages. Every page has a proven domain.")}
          </p>
        </div>
        <.link
          navigate={~p"/companies/new"}
          class="rounded-lg bg-brand-600 px-4 py-2 text-center text-sm font-semibold text-white hover:bg-brand-700"
        >
          {gettext("Claim your company")}
        </.link>
      </div>

      <form phx-change="search" phx-submit="search" class="mb-6">
        <label for="company-search" class="sr-only">{gettext("Search companies")}</label>
        <input
          type="search"
          name="q"
          id="company-search"
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
              {gettext("No company pages yet. Be the first to claim yours.")}
            <% else %>
              {gettext("No companies found for %{term}.", term: @search)}
            <% end %>
          </p>
          <.link
            navigate={~p"/companies/new"}
            class="mt-4 inline-block text-sm font-semibold text-brand-600 hover:text-brand-700"
          >
            {gettext("Claim your company")}
          </.link>
        </.card>
      <% else %>
        <div id="company-directory" class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <.link
            :for={company <- @result.entries}
            navigate={~p"/companies/#{company.slug}"}
            class="flex items-center gap-4 rounded-2xl bg-white p-4 shadow-sm ring-1 ring-slate-200 transition hover:ring-brand-300 dark:bg-slate-900 dark:ring-slate-800"
          >
            <.company_logo company={company} class="h-14 w-14 shrink-0" />
            <div class="min-w-0">
              <p class="truncate font-semibold text-slate-900 dark:text-slate-100">{company.name}</p>
              <.company_location company={company} class="truncate text-sm text-slate-600 dark:text-slate-400" />
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
