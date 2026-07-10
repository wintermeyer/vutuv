defmodule VutuvWeb.Admin.ScreenshotLive do
  @moduledoc """
  The admin view over the post link-screenshot subsystem
  (`Vutuv.Posts.Screenshots`), at `/admin/screenshots`. Two tabs, both
  offset-paginated (`<.pager>`):

    * **Queue** — the unfinished jobs (`pending` / `capturing` / `failed`), so an
      admin can see what is waiting, in flight, or gave up (with the last error);
    * **Gallery** — the captured screenshots, each a thumbnail linked to the
      external page beside a link to the post it belongs to.

  Read-only. Lives in the `:admin` live_session (`on_mount :require_admin`); the
  dead `:admin` pipeline 403s the disconnected render for non-admins.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.UserHelpers, only: [full_name: 1]

  alias Vutuv.Posts
  alias Vutuv.Posts.Screenshots

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    tab = tab_param(params)
    {rows, total} = load(tab, params)

    {:noreply,
     socket
     |> assign(:page_title, gettext("Link screenshots"))
     |> assign(:tab, tab)
     |> assign(:params, params)
     |> assign(:rows, rows)
     |> assign(:total, total)
     |> assign(:counts, Screenshots.counts())}
  end

  defp tab_param(%{"tab" => "gallery"}), do: "gallery"
  defp tab_param(_params), do: "queue"

  defp load("gallery", params), do: Screenshots.gallery_page(params)
  defp load(_queue, params), do: Screenshots.queue_page(params)

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title={gettext("Link screenshots")}
      crumbs={[{gettext("Admin"), ~p"/admin"}, gettext("Link screenshots")]}
    />

    <nav class="mb-4 flex gap-2" aria-label={gettext("Views")}>
      <.link
        patch={~p"/admin/screenshots?tab=queue"}
        class={tab_class(@tab == "queue")}
        aria-current={@tab == "queue" && "page"}
      >
        {gettext("Queue")} <span class="tabular-nums">({compact_count(@counts.queue)})</span>
      </.link>
      <.link
        patch={~p"/admin/screenshots?tab=gallery"}
        class={tab_class(@tab == "gallery")}
        aria-current={@tab == "gallery" && "page"}
      >
        {gettext("Gallery")} <span class="tabular-nums">({compact_count(@counts.ready)})</span>
      </.link>
    </nav>

    <div class="card-list">
      <section class="card">
        <%= if @tab == "gallery" do %>
          <h1>{gettext("Captured screenshots")}</h1>
          <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
            {gettext("Every captured link screenshot, newest first. Each links to the page and its post.")}
          </p>

          <p :if={@rows == []} class="card__empty">{gettext("No screenshots captured yet.")}</p>

          <div :if={@rows != []} class="mt-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            <div :for={ps <- @rows} id={"screenshot-#{ps.id}"} class="min-w-0">
              <a href={ps.url} target="_blank" rel="noopener" class="block">
                <img
                  src={Vutuv.Screenshot.url({ps.screenshot, ps}, :thumb)}
                  width="400"
                  height="264"
                  loading="lazy"
                  alt=""
                  class="aspect-[400/264] w-full rounded-lg object-cover ring-1 ring-slate-200 dark:ring-slate-800"
                />
              </a>
              <p class="mt-2 truncate text-sm">
                <.link navigate={Posts.path(ps.post)} class="font-semibold text-brand-600 hover:text-brand-700">
                  {gettext("Post by %{name}", name: full_name(ps.post.user))}
                </.link>
              </p>
              <p class="breakwrap text-xs text-slate-600 dark:text-slate-400">
                <a href={ps.url} target="_blank" rel="noopener">{ps.url}</a>
              </p>
              <p class="text-xs text-slate-600 dark:text-slate-400">
                <.local_time :if={ps.captured_at} at={ps.captured_at} id={"captured-#{ps.id}"} />
              </p>
            </div>
          </div>
        <% else %>
          <h1>{gettext("Queue")}</h1>
          <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
            {gettext("Jobs waiting, in flight, or given up. The worker retries transient failures with backoff and re-queues anything a restart left mid-capture.")}
          </p>

          <p :if={@rows == []} class="card__empty">{gettext("The queue is empty.")}</p>

          <div :if={@rows != []} class="card__tablewrap">
            <table class="pure-table">
              <thead>
                <tr>
                  <th>{gettext("Status")}</th>
                  <th>{gettext("URL")}</th>
                  <th>{gettext("Post")}</th>
                  <th>{gettext("Tries")}</th>
                  <th>{gettext("Last error")}</th>
                  <th>{gettext("Queued")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={ps <- @rows} id={"job-#{ps.id}"}>
                  <td><.status_badge status={ps.status} /></td>
                  <td class="breakwrap">
                    <a href={ps.url} target="_blank" rel="noopener">{ps.url}</a>
                  </td>
                  <td>
                    <.link navigate={Posts.path(ps.post)}>
                      @{ps.post.user.username}
                    </.link>
                  </td>
                  <td class="tabular-nums">{ps.attempts}</td>
                  <td class="breakwrap text-slate-600 dark:text-slate-400">{ps.last_error}</td>
                  <td><.local_time at={ps.inserted_at} id={"queued-#{ps.id}"} /></td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>

        <.pager
          params={@params}
          total={@total}
          per_page={Screenshots.per_page()}
          query={%{"tab" => @tab}}
        />
      </section>
    </div>
    """
  end

  # A tab link: the active one is a brand pill, the rest quiet.
  defp tab_class(true),
    do: "rounded-lg bg-brand-600 px-3 py-1.5 text-sm font-semibold text-white"

  defp tab_class(false),
    do:
      "rounded-lg bg-slate-100 px-3 py-1.5 text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"

  attr(:status, :string, required: true)

  # A small colored status pill: pending slate, capturing brand, ready emerald,
  # failed red. Emerald is the app's "active/done" language (the presence dot).
  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex rounded-full px-2 py-0.5 text-xs font-semibold",
      status_badge_class(@status)
    ]}>
      {status_label(@status)}
    </span>
    """
  end

  defp status_badge_class("pending"),
    do: "bg-slate-100 text-slate-700 dark:bg-slate-800 dark:text-slate-200"

  defp status_badge_class("capturing"),
    do: "bg-brand-100 text-brand-700 dark:bg-brand-900/40 dark:text-brand-100"

  defp status_badge_class("ready"),
    do: "bg-emerald-100 text-emerald-800 dark:bg-emerald-900/40 dark:text-emerald-200"

  defp status_badge_class("failed"),
    do: "bg-red-100 text-red-800 dark:bg-red-900/40 dark:text-red-200"

  defp status_badge_class(_other),
    do: "bg-slate-100 text-slate-700 dark:bg-slate-800 dark:text-slate-200"

  defp status_label("pending"), do: gettext("Pending")
  defp status_label("capturing"), do: gettext("Capturing")
  defp status_label("ready"), do: gettext("Ready")
  defp status_label("failed"), do: gettext("Failed")
  defp status_label(other), do: other
end
