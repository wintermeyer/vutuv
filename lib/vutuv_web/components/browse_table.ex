defmodule VutuvWeb.BrowseTable do
  @moduledoc """
  The shared machinery behind the two Fediverse relationship tables: the
  member's remote **followers** (`VutuvWeb.FediverseFollowersLive`) and the
  accounts they **follow** out there (`VutuvWeb.FediverseFollowingLive`, issue
  #1160).

  They are the same relationship read from opposite ends, so they behave
  identically: search, a server filter, sortable column headers and numbered
  paging, all of it in the **URL** (`push_patch`) so a particular view is
  shareable and the back button restores it. That behaviour lives here rather
  than twice, which is also what keeps a `?sort=` value meaning the same thing
  on both pages — and it is the markup as much as the query string, since a
  copied `<select>` is exactly how the "current filter always shows" fallback
  would end up fixed on one page only.

  What stays with each page is what genuinely differs: which rows it loads,
  which columns it shows, and what a row lets you do.
  """

  use Phoenix.Component
  use Gettext, backend: VutuvWeb.Gettext

  import VutuvWeb.UI

  alias Vutuv.Fediverse

  @doc """
  The current view as a URL query map, with `overrides` applied.

  Blanks and defaults are left out, so the unfiltered view is a bare path and a
  filtered one is a clean, shareable URL. `page` is dropped unless it is
  overridden, so any filter or sort change goes back to page 1.
  """
  def build_query(filters, overrides \\ %{}) do
    %{
      "q" => filters.q,
      "server" => filters.server,
      "sort" => filters.sort,
      "dir" => filters.dir
    }
    |> Map.merge(overrides)
    |> drop_defaults()
  end

  defp drop_defaults(query) do
    default_sort = Fediverse.browse_default_sort()
    sort = query["sort"] || default_sort

    query
    |> Enum.reject(fn
      {_key, value} when value in [nil, ""] -> true
      {"sort", ^default_sort} -> true
      {"dir", dir} -> dir == Fediverse.browse_default_dir(sort)
      {"page", "1"} -> true
      {_key, _value} -> false
    end)
    |> Map.new()
  end

  @doc """
  Any narrowing of the full list — what the empty state keys on. A sort is not a
  filter: it hides nothing.
  """
  def filtered?(filters), do: filters.q != nil or filters.server != nil

  # Whether the view differs from a fresh page load at all, filter or sort.
  #
  # The reset control keys on this rather than on `filtered?/1`, because on a
  # phone the sortable columns other than Account are folded away: tap Account
  # once and the only control that could put the default order back would not
  # render, since a sort narrows nothing. That is a trap you cannot leave
  # without editing the URL.
  defp default_view?(filters) do
    not filtered?(filters) and
      filters.sort == Fediverse.browse_default_sort() and
      filters.dir == Fediverse.browse_default_dir(filters.sort)
  end

  @doc """
  The direction a click on `column` should sort in: the other way round when it
  is already the active column, else that column's own default.
  """
  def next_dir(filters, column) do
    if filters.sort == column,
      do: flip(filters.dir),
      else: Fediverse.browse_default_dir(column)
  end

  # The direction a column flips to when its header is clicked again.
  defp flip("asc"), do: "desc"
  defp flip(_desc), do: "asc"

  # The `aria-sort` value for a column header.
  defp aria_sort(%{sort: column, dir: "asc"}, column), do: "ascending"
  defp aria_sort(%{sort: column}, column), do: "descending"
  defp aria_sort(_filters, _column), do: "none"

  @doc """
  The utilities that fold a column away on a phone.

  A handle already ends in the server it lives on, so the Server column is the
  first thing that can go when the table would otherwise push a date past the
  card edge; the server *filter* stays reachable through the dropdown at every
  width. Named here because both tables make the same call and a phone is the
  width to judge them at.
  """
  def phone_hidden_class, do: "hidden sm:table-cell"

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
  The search box, the server dropdown and the Clear control.

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
        :if={not default_view?(@filters)}
        type="button"
        phx-click="clear"
        id="clear-filters"
        class="min-h-10 px-2 text-sm font-semibold text-slate-600 hover:text-slate-800 dark:text-slate-400 dark:hover:text-slate-200"
      >
        <%= if filtered?(@filters) do %>
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

  @doc """
  Where you are in the list and how to leave it: the "1-50 of 12,483" line and
  the numbered pager, which carries the active filter and sort onto every page
  link. Exact figures, because knowing where you are in a long list is the
  whole point of the line.
  """
  def browse_footer(assigns) do
    assigns =
      assigns
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
      query={build_query(@filters)}
    />
    """
  end

  defp range_first(page, per_page, total) when total > 0, do: (page - 1) * per_page + 1
  defp range_first(_page, _per_page, _total), do: 0
end
