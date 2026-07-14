defmodule VutuvWeb.SavedSearchComponents do
  @moduledoc """
  The shared "Save search" control (issue #935) and the small label helpers for
  saved searches. The control is one quiet button that expands into a cadence
  picker; the host LiveView (the job board or the people search) owns the two
  events it emits — `toggle_save_search` and `save_search` (with a `notify`
  param) — and builds the query string from its own filter state. DRY across
  both sides of the market.
  """
  use VutuvWeb, :html

  alias Vutuv.SavedSearches
  alias Vutuv.SavedSearches.SavedSearch

  @doc "Cadence options `{label, value}` for the alert-cadence select."
  def cadence_options, do: Enum.map(SavedSearch.cadences(), &{cadence_label(&1), &1})

  @doc "The human label for an alert cadence."
  def cadence_label(:none), do: gettext("No emails")
  def cadence_label(:daily), do: gettext("Daily email")
  def cadence_label(:weekly), do: gettext("Weekly email")

  @doc "The kind badge label for a saved search."
  def saved_search_kind_label(:jobs), do: gettext("Jobs")
  def saved_search_kind_label(:people), do: gettext("People")

  @doc "The human summary line of a saved search's filters (empty = the whole listing)."
  def saved_search_summary(%SavedSearch{} = search) do
    case SavedSearches.summary_segments(search) do
      [] -> gettext("Everything")
      segments -> Enum.join(segments, " · ")
    end
  end

  @doc """
  The quiet "Save search" control. `show?` expands the cadence picker; `saved?`
  swaps it for a done state linking to the management page. Defaults to `:none`
  so saving never silently subscribes anyone (issue #935).
  """
  attr(:id, :string, default: "save-search")
  attr(:show?, :boolean, default: false)
  attr(:saved?, :boolean, default: false)
  attr(:class, :string, default: nil)

  def save_search_control(assigns) do
    ~H"""
    <div id={@id} class={@class}>
      <p :if={@saved?} id={"#{@id}-done"} class="text-sm text-slate-600 dark:text-slate-400">
        {gettext("Search saved.")}
        <.link navigate={~p"/settings/saved_searches"} class="font-semibold text-brand-600 hover:text-brand-700">
          {gettext("Manage your saved searches")}
        </.link>
      </p>

      <form
        :if={not @saved? and @show?}
        id={"#{@id}-form"}
        phx-submit="save_search"
        class="flex flex-wrap items-center gap-2"
      >
        <span class="text-sm font-medium text-slate-700 dark:text-slate-200">
          {gettext("Email me")}:
        </span>
        <select name="notify" class={[input_class(), "w-auto py-1.5 text-sm"]} aria-label={gettext("Alert frequency")}>
          <option :for={{label, value} <- cadence_options()} value={value}>{label}</option>
        </select>
        <button
          type="submit"
          class="rounded-lg bg-brand-600 px-3 py-1.5 text-sm font-semibold text-white hover:bg-brand-700"
        >
          {gettext("Save search")}
        </button>
        <button
          type="button"
          phx-click="toggle_save_search"
          class="text-sm font-semibold text-slate-600 hover:text-slate-800 dark:text-slate-400"
        >
          {gettext("Cancel")}
        </button>
      </form>

      <button
        :if={not @saved? and not @show?}
        id={"#{@id}-button"}
        type="button"
        phx-click="toggle_save_search"
        class="inline-flex items-center gap-1.5 rounded-lg bg-slate-100 px-3 py-1.5 text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
      >
        <svg class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke-width="1.8" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" d="M17.593 3.322c1.1.128 1.907 1.077 1.907 2.185V21L12 17.25 4.5 21V5.507c0-1.108.806-2.057 1.907-2.185a48.507 48.507 0 0 1 11.186 0Z" />
        </svg>
        {gettext("Save search")}
      </button>
    </div>
    """
  end
end
