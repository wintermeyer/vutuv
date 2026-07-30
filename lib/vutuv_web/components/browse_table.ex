defmodule VutuvWeb.BrowseTable do
  @moduledoc """
  The shared machinery behind the browse/table LiveViews: the two Fediverse
  relationship tables (`VutuvWeb.FediverseFollowersLive` and
  `VutuvWeb.FediverseFollowingLive`, issue #1160), the member's own
  account-activity log (`VutuvWeb.AccountActivityLive`), its admin twin
  (`VutuvWeb.Admin.ActivityLive`) and the admin member browser
  (`VutuvWeb.Admin.UserLive`).

  They all behave the same way: search, filters, sortable column headers and
  numbered paging, all of it in the **URL** (`push_patch`) so a particular view
  is shareable and the back button restores it. That behaviour lives here
  rather than five times, which is also what keeps a `?sort=` value meaning
  the same thing on every page. What differs per page — the filter vocabulary
  and the sort defaults — is named once in a `browse_config/1` map and handed
  to `build_query/3`, `filtered?/2` and `next_dir/3`.

  What stays with each page is what genuinely differs: which rows it loads,
  which columns it shows, and what a row lets you do.
  """

  use Phoenix.Component
  use Gettext, backend: VutuvWeb.Gettext

  import Phoenix.LiveView, only: [push_patch: 2]
  import VutuvWeb.UI

  alias Vutuv.Fediverse

  @doc """
  Names what differs between the browse pages, so the URL machinery below can
  be shared:

    * `:filter_keys` — the filter fields (atoms) the page's filter map carries
      beside `sort`/`dir`; each rides the URL under its own name.
    * `:defaults` — per-key default values (string keys) a shareable URL
      leaves out, for filters whose default is not blank (the member browser's
      `reg=pin`). Blank (`nil`/`""`) values are always left out.
    * `:default_sort` — the column the page sorts by until somebody clicks a
      header.
    * `:default_dir` — the direction a freshly clicked column sorts in, as a
      fun of the column.
    * `:url_default_dir` — the direction the page's filter parser assumes when
      the URL names none (so it is dropped from the query string). Defaults to
      `:default_dir`; the member browser is the one page where the two differ
      (a fresh column sorts A-Z, a bare URL means newest-first).
  """
  def browse_config(opts) do
    default_dir = Keyword.fetch!(opts, :default_dir)

    %{
      filter_keys: Keyword.fetch!(opts, :filter_keys),
      defaults: Keyword.get(opts, :defaults, %{}),
      default_sort: Keyword.fetch!(opts, :default_sort),
      default_dir: default_dir,
      url_default_dir: Keyword.get(opts, :url_default_dir, default_dir)
    }
  end

  @doc """
  The config for the two Fediverse relationship tables. They are the same
  relationship read from opposite ends, so they share everything down to the
  filter vocabulary — and `Vutuv.Fediverse` owns the sort defaults.
  """
  def fediverse_config do
    browse_config(
      filter_keys: [:q, :server],
      default_sort: Fediverse.browse_default_sort(),
      default_dir: &Fediverse.browse_default_dir/1
    )
  end

  @doc """
  The current view as a URL query map, with `overrides` applied.

  Blanks and defaults are left out, so the unfiltered view is a bare path and a
  filtered one is a clean, shareable URL. `page` is dropped unless it is
  overridden, so any filter or sort change goes back to page 1.
  """
  def build_query(filters, config, overrides \\ %{}) do
    config.filter_keys
    |> Map.new(&{Atom.to_string(&1), Map.fetch!(filters, &1)})
    |> Map.merge(%{"sort" => filters.sort, "dir" => filters.dir})
    |> Map.merge(overrides)
    |> drop_defaults(config)
  end

  defp drop_defaults(query, config) do
    sort = query["sort"] || config.default_sort

    query
    |> Enum.reject(fn
      {_key, value} when value in [nil, ""] -> true
      {"sort", value} -> value == config.default_sort
      {"dir", value} -> value == config.url_default_dir.(sort)
      {"page", "1"} -> true
      {key, value} -> Map.get(config.defaults, key) == value
    end)
    |> Map.new()
  end

  @doc """
  Any narrowing of the full list — what the empty state keys on. A sort is not a
  filter: it hides nothing.
  """
  def filtered?(filters, config) do
    Enum.any?(config.filter_keys, fn key ->
      Map.fetch!(filters, key) != Map.get(config.defaults, Atom.to_string(key))
    end)
  end

  # Whether the view differs from a fresh page load at all, filter or sort.
  #
  # The reset control keys on this rather than on `filtered?/2`, because on a
  # phone the sortable columns other than Account are folded away: tap Account
  # once and the only control that could put the default order back would not
  # render, since a sort narrows nothing. That is a trap you cannot leave
  # without editing the URL.
  defp default_view?(filters, config) do
    not filtered?(filters, config) and
      filters.sort == config.default_sort and
      filters.dir == config.url_default_dir.(filters.sort)
  end

  @doc """
  The direction a click on `column` should sort in: the other way round when it
  is already the active column, else that column's own default.
  """
  def next_dir(filters, config, column) do
    if filters.sort == column,
      do: flip(filters.dir),
      else: config.default_dir.(column)
  end

  # The direction a column flips to when its header is clicked again.
  defp flip("asc"), do: "desc"
  defp flip(_desc), do: "asc"

  # The `aria-sort` value for a column header.
  defp aria_sort(%{sort: column, dir: "asc"}, column), do: "ascending"
  defp aria_sort(%{sort: column}, column), do: "descending"
  defp aria_sort(_filters, _column), do: "none"

  @doc """
  Handles the browse events the two Fediverse tables share — `"filter"`,
  `"sort"`, `"filter_server"` and `"clear"` — each of which just rewrites the
  URL and lets `handle_params/3` reload. `path_fun` turns a query map into the
  page's own path, so the route literal is the one thing each page keeps.
  """
  # Replaced, not pushed: the search box is debounced but still fires per burst
  # of typing, and on a phone the back gesture is the way out of a page.
  # Pushing would make leaving take one press per search term.
  def handle_browse_event("filter", params, socket, path_fun) do
    {:noreply,
     patch_browse(socket, %{"q" => params["q"], "server" => params["server"]}, path_fun,
       replace: true
     )}
  end

  def handle_browse_event("sort", %{"col" => col}, socket, path_fun) do
    dir = next_dir(socket.assigns.filters, fediverse_config(), col)
    {:noreply, patch_browse(socket, %{"sort" => col, "dir" => dir}, path_fun)}
  end

  # A server name in a row is a filter you can click: at ten thousand rows
  # "show me everyone else from this server" is the question the list raises.
  def handle_browse_event("filter_server", %{"host" => host}, socket, path_fun) do
    {:noreply, patch_browse(socket, %{"server" => host}, path_fun)}
  end

  def handle_browse_event("clear", _params, socket, path_fun) do
    {:noreply, push_patch(socket, to: path_fun.(%{}))}
  end

  @doc """
  The current Fediverse browse view with `overrides` applied, as a
  `push_patch` to `path_fun`'s page.
  """
  def patch_browse(socket, overrides, path_fun, opts \\ []) do
    query = build_query(socket.assigns.filters, fediverse_config(), overrides)
    push_patch(socket, [to: path_fun.(query)] ++ opts)
  end

  @doc """
  The utilities that fold a column away on a phone.

  A handle already ends in the server it lives on, so the Server column is the
  first thing that can go when the table would otherwise push a date past the
  card edge; the server *filter* stays reachable through the dropdown at every
  width. Named here because both tables make the same call and a phone is the
  width to judge them at.
  """
  def phone_hidden_class, do: "hidden sm:table-cell"

  attr(:id, :string, required: true)
  attr(:count, :integer, required: true)

  @doc """
  The headline count pill beside a browse page's title: the exact size of the
  whole list, whatever the current view filters out of it.
  """
  def count_pill(assigns) do
    ~H"""
    <span
      id={@id}
      class="rounded-full bg-slate-100 px-2 py-0.5 text-sm font-semibold text-slate-600 dark:bg-slate-800 dark:text-slate-300"
    >
      {delimited_count(@count)}
    </span>
    """
  end

  attr(:col, :string, required: true)
  attr(:label, :string, required: true)
  attr(:filters, :map, required: true)
  attr(:class, :string, default: nil)

  @doc """
  One sortable column header: the label, the active column's direction caret,
  and the `aria-sort` state. Fires `"sort"` with `phx-value-col` on the host
  LiveView, which rewrites the URL and lets `handle_params/3` reload.
  """
  def sort_header(assigns) do
    ~H"""
    <th aria-sort={aria_sort(@filters, @col)} class={@class}>
      <button
        type="button"
        phx-click="sort"
        phx-value-col={@col}
        id={"sort-#{@col}"}
        class="inline-flex min-h-10 items-center font-semibold text-slate-700 hover:text-brand-700 dark:text-slate-200 dark:hover:text-brand-300"
      >
        {@label}{sort_caret(@filters, @col)}
      </button>
    </th>
    """
  end

  defp sort_caret(filters, column) do
    cond do
      filters.sort != column -> ""
      filters.dir == "asc" -> " ▲"
      true -> " ▼"
    end
  end

  attr(:id, :string, required: true)
  attr(:filters, :map, required: true)
  attr(:hosts, :list, required: true)
  attr(:class, :string, default: nil)

  @doc """
  The search box, the server dropdown and the Clear control of the Fediverse
  tables.

  One form for both controls, so typing and picking a server are the same round
  trip. Debounced, since every keystroke is a query over the member's whole
  list. Fires `"filter"` on the host LiveView; `"clear"` drops back to the bare
  path.
  """
  def filter_form(assigns) do
    ~H"""
    <form
      id={@id}
      phx-change="filter"
      phx-submit="filter"
      class={["flex flex-wrap items-end gap-3", @class]}
    >
      <div class="min-w-48 grow">
        <label for="filter-q" class="block text-sm font-semibold text-slate-700 dark:text-slate-200">
          {gettext("Search")}
        </label>
        <input
          type="search"
          name="q"
          id="filter-q"
          value={@filters.q}
          phx-debounce="250"
          autocomplete="off"
          placeholder={gettext("name, handle or server")}
          class={input_class()}
        />
      </div>
      <div :if={@hosts != []}>
        <label
          for="filter-server"
          class="block text-sm font-semibold text-slate-700 dark:text-slate-200"
        >
          {gettext("Server")}
        </label>
        <select name="server" id="filter-server" class={input_class()}>
          <option value="" selected={is_nil(@filters.server)}>
            {gettext("All servers")}
          </option>
          <%!-- The current filter always shows, even when it is not among the
          biggest servers offered — otherwise a shared link would render a
          select that contradicts the list below it. --%>
          <option
            :if={@filters.server && @filters.server not in Enum.map(@hosts, & &1.host)}
            value={@filters.server}
            selected
          >
            {@filters.server}
          </option>
          <option :for={host <- @hosts} value={host.host} selected={@filters.server == host.host}>
            {host.host} ({compact_count(host.count)})
          </option>
        </select>
      </div>
      <button
        :if={not default_view?(@filters, fediverse_config())}
        type="button"
        phx-click="clear"
        id="clear-filters"
        class="min-h-10 px-2 text-sm font-semibold text-slate-600 hover:text-slate-800 dark:text-slate-400 dark:hover:text-slate-200"
      >
        <%= if filtered?(@filters, fediverse_config()) do %>
          {gettext("Clear filters")}
        <% else %>
          {gettext("Reset sorting")}
        <% end %>
      </button>
    </form>
    """
  end

  attr(:uri, :string, required: true)
  attr(:name, :string, default: nil)
  attr(:handle, :string, required: true)

  @doc """
  The Account cell's content: the display name over the `@user@server` handle,
  both linking out to the account on its own server.
  """
  def account_link(assigns) do
    ~H"""
    <a href={@uri} target="_blank" rel="nofollow noopener noreferrer" class="group block min-w-0">
      <span
        :if={@name}
        class="breakwrap block font-medium text-slate-800 group-hover:text-brand-700 dark:text-slate-100 dark:group-hover:text-brand-300"
      >
        {@name}
      </span>
      <%!-- A handle is one long unbreakable token, so on a phone its
      min-content would set the table's width and push the date column past the
      card edge. `break-all` below `sm` lets it wrap onto a second line
      instead; from `sm` up it fits and breaks only at spaces again. --%>
      <span class="block break-all text-slate-600 group-hover:text-brand-600 dark:text-slate-400 dark:group-hover:text-brand-300 sm:break-normal">
        {@handle}
      </span>
    </a>
    """
  end

  attr(:host, :string, required: true)
  attr(:title, :string, required: true)

  @doc """
  The Server cell's content: the server name as a filter you can click. At ten
  thousand rows "show me everyone else from this server" is the question the
  list raises.
  """
  def server_filter(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="filter_server"
      phx-value-host={@host}
      title={@title}
      class="inline-flex min-h-10 items-center text-slate-600 underline decoration-dotted underline-offset-2 hover:text-brand-700 dark:text-slate-400 dark:hover:text-brand-300"
    >
      {@host}
    </button>
    """
  end

  attr(:page, :integer, required: true)
  attr(:per_page, :integer, required: true)
  attr(:total, :integer, required: true)
  attr(:path, :string, required: true)
  attr(:filters, :map, required: true)
  attr(:config, :map, default: nil)

  @doc """
  Where you are in the list and how to leave it: the "1-50 of 12,483" line and
  the numbered pager, which carries the active filter and sort onto every page
  link. Exact figures, because knowing where you are in a long list is the
  whole point of the line. `config` names the page's filter vocabulary; left
  out it is the Fediverse pair's.
  """
  def browse_footer(assigns) do
    assigns =
      assigns
      |> assign(:config, assigns.config || fediverse_config())
      |> assign(:first, range_first(assigns.page, assigns.per_page, assigns.total))
      |> assign(:last, min(assigns.page * assigns.per_page, assigns.total))

    ~H"""
    <p class="mt-3 text-xs text-slate-600 dark:text-slate-400">
      {gettext("Showing %{first}-%{last} of %{total}.",
        first: delimited_count(@first),
        last: delimited_count(@last),
        total: delimited_count(@total)
      )}
    </p>

    <.pager
      params={%{"page" => @page}}
      total={@total}
      per_page={@per_page}
      path={@path}
      query={build_query(@filters, @config)}
    />
    """
  end

  defp range_first(page, per_page, total) when total > 0, do: (page - 1) * per_page + 1
  defp range_first(_page, _per_page, _total), do: 0
end
