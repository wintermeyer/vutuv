defmodule VutuvWeb.Admin.MediaLive do
  @moduledoc """
  Every media job the installation has run, running and past (`/admin/media`,
  issue #2103).

  When a photo scan or a video conversion is slow or stuck, nothing in the
  admin area says so: each pipeline keeps a status column on its own row, and
  how long a step took only ever reached the server log. This page is the plain
  log of `Vutuv.MediaJobs` — what ran, what it worked on, when it started and
  finished, how long it took and how it ended — with one search over member,
  kind and outcome, a sort on every column and numbered paging.

  Read-only: there is nothing to press here but a column header. Search, sort
  and page live in the **URL** (`push_patch`) via the shared
  `VutuvWeb.BrowseTable` machinery, so a view is shareable inside the team and
  the back button restores it. Lives in the `:admin` live_session
  (`on_mount :require_admin`, see the router) — the dead `:admin` pipeline 403s
  the disconnected render and the on_mount guards the socket.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.Admin.MemberBadges, only: [badge_class: 1]
  import VutuvWeb.BrowseTable
  import VutuvWeb.UserHelpers, only: [member_name: 1]

  alias Vutuv.MediaJobs
  alias Vutuv.Pages
  alias Vutuv.Posts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, gettext("Media jobs"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = MediaJobs.filters(params)
    per_page = MediaJobs.jobs_per_page()
    total = MediaJobs.count(filters)
    page = Pages.effective_page(params, total, per_page)

    jobs = MediaJobs.page(filters, %{"page" => page}, total: total, per_page: per_page)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:total, total)
     |> assign(:page, page)
     |> assign(:per_page, per_page)
     |> assign(:jobs, jobs)}
  end

  # ── Events (every one just rewrites the URL; handle_params reloads) ──

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, patch(socket, %{"q" => params["q"]})}
  end

  def handle_event("sort", %{"col" => col}, socket) do
    dir = next_dir(socket.assigns.filters, browse_config(), col)
    {:noreply, patch(socket, %{"sort" => col, "dir" => dir})}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/media")}
  end

  defp patch(socket, overrides) do
    query = build_query(socket.assigns.filters, browse_config(), overrides)
    push_patch(socket, to: ~p"/admin/media?#{query}")
  end

  defp browse_config do
    browse_config(
      filter_keys: [:q],
      default_sort: "started",
      default_dir: &MediaJobs.default_dir/1
    )
  end

  # Every column the table shows is sortable, which is the whole point of a
  # table you come to with "what is taking so long".
  defp columns do
    [
      {"started", gettext("Started")},
      {"member", gettext("Member")},
      {"kind", gettext("Job")},
      {"outcome", gettext("Outcome")},
      {"duration", gettext("Took")}
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title={gettext("Media jobs")}
      crumbs={[{gettext("Admin"), ~p"/admin"}, gettext("Media jobs")]}
    />

    <div class="card-list">
      <section class="card">
        <p class="text-sm leading-relaxed text-slate-600 dark:text-slate-400">
          {gettext(
            "Every step the photo scan, the video conversion and the screenshot capture have run - what they worked on, how long it took and how it ended. A job still marked as running is one that has not come back yet."
          )}
        </p>

        <form
          id="media-filter"
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
              placeholder={gettext("member, kind or outcome")}
              class={input_class()}
            />
          </div>
          <%!-- Keyed on the whole view, not on `filtered?/2`: a page that has
          only been re-sorted must still offer a way back, or a phone (where
          the other headers fold away) is a trap. --%>
          <button
            :if={not default_view?(@filters, browse_config())}
            type="button"
            phx-click="clear"
            id="clear-filters"
            class="min-h-10 px-2 text-sm font-semibold text-slate-600 hover:text-slate-800 dark:text-slate-400 dark:hover:text-slate-200"
          >
            <%= if filtered?(@filters, browse_config()) do %>
              {gettext("Clear filters")}
            <% else %>
              {gettext("Reset sorting")}
            <% end %>
          </button>
        </form>

        <p :if={@jobs == []} class="card__empty" id="no-media-jobs">
          <%= if filtered?(@filters, browse_config()) do %>
            {gettext("Nothing matches that. Try a shorter search, or clear the filters.")}
          <% else %>
            {gettext("No media job has run yet.")}
          <% end %>
        </p>

        <div :if={@jobs != []} class="card__tablewrap mt-4">
          <table class="pure-table">
            <thead>
              <tr>
                <.sort_header
                  :for={{col, header} <- columns()}
                  col={col}
                  label={header}
                  filters={@filters}
                />
              </tr>
            </thead>
            <tbody id="media-jobs">
              <tr :for={job <- @jobs} id={"media-job-#{job.id}"}>
                <td class="whitespace-nowrap align-top text-slate-600 dark:text-slate-400">
                  <.local_time
                    at={job.started_at}
                    id={"started-#{job.id}"}
                    precision="second"
                    format="%Y-%m-%d %H:%M:%S"
                  />
                </td>
                <td class="align-top">
                  <%= if job.user do %>
                    <.link
                      navigate={~p"/admin/users/#{job.user.id}"}
                      class="block whitespace-nowrap text-slate-600 hover:text-brand-700 dark:text-slate-400 dark:hover:text-brand-300"
                    >
                      @{job.user.username}
                    </.link>
                    <span class="block text-xs text-slate-600 dark:text-slate-400">
                      {member_name(job.user)}
                    </span>
                  <% else %>
                    <span class="text-slate-500 dark:text-slate-400">{gettext("nobody")}</span>
                  <% end %>
                </td>
                <td class="align-top">
                  <span class="block font-medium text-slate-800 dark:text-slate-100">
                    {kind_label(job.kind)}
                  </span>
                  <%= if job.post do %>
                    <.link
                      navigate={Posts.path(job.post)}
                      class="block text-slate-600 underline decoration-dotted underline-offset-2 hover:text-brand-700 dark:text-slate-400 dark:hover:text-brand-300"
                    >
                      {subject_label(job)}
                    </.link>
                  <% else %>
                    <span :if={job.subject_type} class="breakwrap block text-slate-600 dark:text-slate-400">
                      {subject_label(job)}
                    </span>
                  <% end %>
                </td>
                <td class="align-top">
                  <% {label, tone} = outcome_badge(job) %>
                  <.status_pill tone={tone}>{label}</.status_pill>
                  <span
                    :if={job.detail}
                    class="breakwrap mt-1 block text-slate-600 dark:text-slate-400"
                    data-job-detail
                  >
                    {job.detail}
                  </span>
                </td>
                <td class="whitespace-nowrap align-top text-slate-600 dark:text-slate-400">
                  {duration(MediaJobs.elapsed_ms(job))}
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <.browse_footer
          :if={@jobs != []}
          page={@page}
          per_page={@per_page}
          total={@total}
          path={~p"/admin/media"}
          filters={@filters}
          config={browse_config()}
        />
      </section>
    </div>
    """
  end

  # The pipeline, said the way an operator would name it rather than by its
  # module. New kinds land in the `_other` clause as their stored word rather
  # than as a crash, so adding one to `Vutuv.MediaJobs` cannot 500 this page.
  defp kind_label("image_scan"), do: gettext("Photo scan")
  defp kind_label("video_conversion"), do: gettext("Video conversion")
  defp kind_label("screenshot"), do: gettext("Link screenshot")
  defp kind_label("attachment_intake"), do: gettext("File check")
  defp kind_label(other), do: other

  # What the step worked on: the subject's kind, and enough of its id to tell
  # two rows apart in a log without printing a 36-character UUID in a table
  # cell. The id itself is not a link — the post beside it is.
  defp subject_label(%{subject_type: type, subject_id: nil}), do: type

  defp subject_label(%{subject_type: type, subject_id: id}),
    do: "#{type} · #{String.slice(id, 0, 8)}"

  # The admin pill palette, not three hand-written tones: `badge_class/1` is
  # where the admin area's greens, roses and brand tints already live, so a
  # fifth palette here would be the one that drifts (and the danger tone is
  # rose — a red pill would be the only one in the tree).
  defp outcome_badge(%{status: "done"}), do: {gettext("Done"), badge_class(:verified)}
  defp outcome_badge(%{status: "failed"}), do: {gettext("Failed"), badge_class(:danger)}
  defp outcome_badge(_running), do: {gettext("Running"), badge_class(:admin)}
end
