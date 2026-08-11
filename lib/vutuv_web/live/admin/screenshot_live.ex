defmodule VutuvWeb.Admin.ScreenshotLive do
  @moduledoc """
  The admin view over the post link-screenshot subsystem
  (`Vutuv.Posts.Screenshots`), at `/admin/screenshots`. Three tabs:

    * **Queue** — the unfinished jobs (`pending` / `capturing` / `failed`), so an
      admin can see what is waiting, in flight, or gave up (with the last error),
      and hand a `failed` one back to the worker ("Retry"), which is the only
      way a job past the retry cap is ever captured again;
    * **Gallery** — the captured screenshots, each a thumbnail linked to the
      external page beside a link to the post it belongs to;
    * **Blocklist** — the editor for the pages this installation never captures
      (`Vutuv.ScreenshotBlocklist`): add a domain or a URL, drop one again, try
      a URL against the list to see what an entry really covers, and clean up
      the captures taken before an entry existed.

  Queue and Gallery are offset-paginated (`<.pager>`); the blocklist is a short
  list an admin reads whole.

  Lives in the `:admin` live_session (`on_mount :require_admin`); the dead
  `:admin` pipeline 403s the disconnected render for non-admins.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.ErrorHelpers, only: [error_tag: 2]
  import VutuvWeb.UserHelpers, only: [full_name: 1]

  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Organizations.Organization
  alias Vutuv.PageScreenshot
  alias Vutuv.Posts
  alias Vutuv.Posts.Screenshots
  alias Vutuv.Posts.ScreenshotWorker
  alias Vutuv.ScreenshotBlocklist

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:check_url, "") |> assign(:check_result, nil)}
  end

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
     |> assign(:counts, Screenshots.counts())
     |> load_blocklist()}
  end

  defp tab_param(%{"tab" => "gallery"}), do: "gallery"
  defp tab_param(%{"tab" => "blocklist"}), do: "blocklist"
  defp tab_param(_params), do: "queue"

  defp load("gallery", params), do: Screenshots.gallery_page(params)
  # The blocklist is short enough to read whole, so it has no pager.
  defp load("blocklist", _params), do: {[], 0}
  defp load(_queue, params), do: Screenshots.queue_page(params)

  # The blocklist itself is cheap (a handful of rows), so both the tab count
  # and the list come along on every render of this page.
  defp load_blocklist(socket) do
    entries = ScreenshotBlocklist.list_entries()

    socket
    |> assign(:entries, entries)
    |> assign(:entry_form, to_form(ScreenshotBlocklist.change_entry()))
    |> assign(:check_result, recheck(socket.assigns[:check_url]))
  end

  @impl true
  def handle_event("requeue", %{"id" => id}, socket) do
    socket =
      case Screenshots.requeue(Screenshots.get_job!(id)) do
        {:ok, _job} ->
          # Capture now rather than at the next slow poll — an admin who clicks
          # retry is watching.
          ScreenshotWorker.nudge()
          put_flash(socket, :info, gettext("Screenshot job queued again."))

        {:error, _reason} ->
          put_flash(socket, :error, gettext("This job cannot be queued again."))
      end

    {:noreply, reload(socket)}
  end

  @impl true
  def handle_event("add-entry", %{"entry" => attrs}, socket) do
    case ScreenshotBlocklist.create_entry(attrs) do
      {:ok, entry} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("%{pattern} is on the blocklist now.", pattern: entry.pattern)
         )
         |> reload()}

      {:error, changeset} ->
        {:noreply, assign(socket, :entry_form, to_form(changeset))}
    end
  end

  def handle_event("delete-entry", %{"id" => id}, socket) do
    entry = ScreenshotBlocklist.get_entry!(id)
    {:ok, _deleted} = ScreenshotBlocklist.delete_entry(entry)

    {:noreply,
     socket
     |> put_flash(:info, gettext("%{pattern} is off the blocklist.", pattern: entry.pattern))
     |> reload()}
  end

  # The "what does this cover?" box: a pattern grammar is exactly where an
  # admin guesses wrong, so they can hold a real URL against the list.
  def handle_event("check-url", %{"url" => url}, socket) do
    {:noreply,
     socket
     |> assign(:check_url, url)
     |> assign(:check_result, recheck(url))}
  end

  def handle_event("purge", _params, socket) do
    links = PageScreenshot.purge_blocklisted()
    posts = Screenshots.purge_blocklisted()

    {:noreply,
     socket
     |> put_flash(
       :info,
       gettext("Removed %{links} link screenshot(s) and %{posts} post screenshot(s).",
         links: links,
         posts: posts
       )
     )
     |> reload()}
  end

  defp recheck(url) when is_binary(url) do
    case String.trim(url) do
      "" -> nil
      trimmed -> {trimmed, ScreenshotBlocklist.blocked?(trimmed)}
    end
  end

  defp recheck(_url), do: nil

  # Re-read the current tab's page, so the row's new status shows at once.
  defp reload(socket) do
    {rows, total} = load(socket.assigns.tab, socket.assigns.params)

    socket
    |> assign(:rows, rows)
    |> assign(:total, total)
    |> assign(:counts, Screenshots.counts())
    |> load_blocklist()
  end

  # Whichever kind of author the post has (issue #1334). A post published in an
  # organization's name has no member behind it here — `post.user` is nil — and
  # a link screenshot is taken for it exactly as it is for a member's post, so
  # both rows on this page meet one.
  defp author_name(post) do
    case Posts.author(post) do
      %Organization{name: name} -> name
      author -> full_name(author)
    end
  end

  # The compact queue-table form: a member is named by handle, a page by name
  # (it may not have claimed a handle at all).
  defp author_label(post) do
    case Posts.author(post) do
      %Organization{name: name} -> name
      author -> "@" <> author.username
    end
  end

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
      <.link
        id="tab-blocklist"
        patch={~p"/admin/screenshots?tab=blocklist"}
        class={tab_class(@tab == "blocklist")}
        aria-current={@tab == "blocklist" && "page"}
      >
        {gettext("Blocklist")}
        <span class="tabular-nums">({compact_count(length(@entries))})</span>
      </.link>
    </nav>

    <div class="card-list">
      <section class="card">
        <%= cond do %>
          <% @tab == "blocklist" -> %>
            <h1>{gettext("Blocklist")}</h1>
            <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
              {gettext(
                "Pages this installation never screenshots. Some sites answer a headless capture with a cookie banner, a login wall or a bot check, so the picture shows the dialog instead of the page. Nothing else changes for a listed link: a post shows the plain link, and a profile link shows the site's name in place of a thumbnail."
              )}
            </p>

            <.form
              for={@entry_form}
              id="blocklist-form"
              phx-submit="add-entry"
              class="mt-4 flex flex-wrap items-start gap-2"
            >
              <div class="min-w-0 flex-1">
                <input
                  type="text"
                  id="blocklist-pattern"
                  name="entry[pattern]"
                  value={@entry_form[:pattern].value}
                  placeholder="heise.de"
                  autocomplete="off"
                  aria-label={gettext("Domain or URL")}
                  aria-invalid={@entry_form[:pattern].errors != [] && "true"}
                  class={input_class(@entry_form, :pattern)}
                />
                {error_tag(@entry_form, :pattern)}
              </div>
              <div class="min-w-0 flex-1">
                <input
                  type="text"
                  id="blocklist-note"
                  name="entry[note]"
                  value={@entry_form[:note].value}
                  placeholder={gettext("Why (optional)")}
                  autocomplete="off"
                  aria-label={gettext("Note")}
                  class={input_class(@entry_form, :note)}
                />
                {error_tag(@entry_form, :note)}
              </div>
              <.button type="submit" id="blocklist-add">{gettext("Add")}</.button>
            </.form>

            <details class="mt-3 text-sm text-slate-600 dark:text-slate-400">
              <summary class="cursor-pointer font-semibold">
                {gettext("What an entry can look like")}
              </summary>
              <ul class="mt-2 space-y-1">
                <li :for={{example, meaning} <- blocklist_examples()}>
                  <code class="font-semibold">{example}</code> {meaning}
                </li>
              </ul>
            </details>

            <h2 class="card__label mt-6">{gettext("Try a URL")}</h2>
            <.form
              for={%{}}
              id="blocklist-check-form"
              phx-change="check-url"
              phx-submit="check-url"
              class="flex flex-wrap items-start gap-2"
            >
              <input
                type="text"
                id="blocklist-check"
                name="url"
                value={@check_url}
                placeholder="https://www.heise.de/news/story-1234.html"
                autocomplete="off"
                phx-debounce="300"
                aria-label={gettext("URL to check")}
                class={[input_class(), "min-w-0 flex-1"]}
              />
            </.form>
            <p :if={@check_result} id="blocklist-check-result" class="mt-2 text-sm">
              <span :if={elem(@check_result, 1)} class="font-semibold text-slate-900 dark:text-slate-100">
                {gettext("Blocked: no screenshot is taken of this page.")}
              </span>
              <span :if={!elem(@check_result, 1)} class="font-semibold text-slate-900 dark:text-slate-100">
                {gettext("Not blocked: this page is captured as usual.")}
              </span>
            </p>

            <h2 class="card__label mt-6">{gettext("Entries")}</h2>
            <p :if={@entries == []} class="card__empty">
              {gettext("The blocklist is empty, so every link is captured.")}
            </p>

            <div :if={@entries != []} class="card__tablewrap">
              <table class="pure-table">
                <thead>
                  <tr>
                    <th>{gettext("Domain or URL")}</th>
                    <th>{gettext("Note")}</th>
                    <th>{gettext("Added")}</th>
                    <th><span class="sr-only">{gettext("Actions")}</span></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @entries} id={"blocklist-entry-#{entry.id}"}>
                    <td class="breakwrap font-semibold">{entry.pattern}</td>
                    <td class="breakwrap text-slate-600 dark:text-slate-400">{entry.note}</td>
                    <td><.local_time at={entry.inserted_at} id={"blocklist-added-#{entry.id}"} /></td>
                    <td>
                      <.button
                        variant="danger"
                        phx-click="delete-entry"
                        phx-value-id={entry.id}
                        data-confirm={
                          gettext("Remove %{pattern} from the blocklist?", pattern: entry.pattern)
                        }
                      >
                        {gettext("Remove")}
                      </.button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <h2 class="card__label mt-6">{gettext("Screenshots taken earlier")}</h2>
            <p class="text-sm text-slate-600 dark:text-slate-400">
              {gettext(
                "Adding an entry stops new captures, but a page captured before it stays on the profile or post that shows it, because nothing re-captures a link whose URL has not changed. This removes every stored screenshot of a page that is on the list today."
              )}
            </p>
            <p class="mt-2">
              <.button
                variant="secondary"
                id="blocklist-purge"
                phx-click="purge"
                phx-disable-with={gettext("Removing…")}
                data-confirm={gettext("Remove the stored screenshots of every blocklisted page?")}
              >
                {gettext("Remove them now")}
              </.button>
            </p>
          <% @tab == "gallery" -> %>
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
                <%!-- A member's post links to its permalink; a cached fediverse
                post has none here, so its origin page stands in. --%>
                <.link
                  :if={ps.post}
                  navigate={Posts.path(ps.post)}
                  class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
                >
                  {gettext("Post by %{name}", name: author_name(ps.post))}
                </.link>
                <a
                  :if={ps.remote_post}
                  href={RemotePost.origin(ps.remote_post)}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
                >
                  {gettext("Post by %{name}",
                    name: RemoteAccount.display_handle(ps.remote_post.remote_account)
                  )}
                </a>
              </p>
              <p class="breakwrap text-xs text-slate-600 dark:text-slate-400">
                <a href={ps.url} target="_blank" rel="noopener">{ps.url}</a>
              </p>
              <p class="text-xs text-slate-600 dark:text-slate-400">
                <.local_time :if={ps.captured_at} at={ps.captured_at} id={"captured-#{ps.id}"} />
              </p>
            </div>
          </div>
          <% true -> %>
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
                  <th><span class="sr-only">{gettext("Actions")}</span></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={ps <- @rows} id={"job-#{ps.id}"}>
                  <td><.status_badge status={ps.status} /></td>
                  <td class="breakwrap">
                    <a href={ps.url} target="_blank" rel="noopener">{ps.url}</a>
                  </td>
                  <td>
                    <.link :if={ps.post} navigate={Posts.path(ps.post)}>
                      {author_label(ps.post)}
                    </.link>
                    <a
                      :if={ps.remote_post}
                      href={RemotePost.origin(ps.remote_post)}
                      target="_blank"
                      rel="noopener noreferrer"
                    >
                      {RemoteAccount.display_handle(ps.remote_post.remote_account)}
                    </a>
                  </td>
                  <td class="tabular-nums">{ps.attempts}</td>
                  <td class="breakwrap text-slate-600 dark:text-slate-400">{ps.last_error}</td>
                  <td><.local_time at={ps.inserted_at} id={"queued-#{ps.id}"} /></td>
                  <td>
                    <.button
                      :if={ps.status == "failed"}
                      variant="secondary"
                      phx-click="requeue"
                      phx-value-id={ps.id}
                      phx-disable-with={gettext("Retrying…")}
                    >
                      {gettext("Retry")}
                    </.button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>

        <.pager
          :if={@tab != "blocklist"}
          params={@params}
          total={@total}
          per_page={Screenshots.per_page()}
          query={%{"tab" => @tab}}
        />
      </section>
    </div>
    """
  end

  # The grammar, by example — the same lines `Vutuv.ScreenshotBlocklist`
  # documents, so an admin never has to read the moduledoc to write an entry.
  defp blocklist_examples do
    [
      {"heise.de", gettext("the site: the domain, every subdomain, every path")},
      {"*.heise.de", gettext("the same rule spelled out")},
      {"example.com/news", gettext("that path and everything below it")},
      {"example.com/*/private", gettext("* stands for exactly one path segment")},
      {"https://example.com/story-1", gettext("one page (the scheme is ignored)")}
    ]
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
