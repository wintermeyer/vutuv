defmodule VutuvWeb.ImportHTML do
  @moduledoc false
  use VutuvWeb, :html

  @doc "One selectable candidate: a checkbox + label, greyed when it is a duplicate."
  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:duplicate?, :boolean, default: false)

  def candidate_row(assigns) do
    ~H"""
    <li class="flex items-start gap-3 py-2">
      <input
        type="checkbox"
        name="selected[]"
        value={@id}
        checked={not @duplicate?}
        class={checkbox_class()}
        id={"cand-#{@id}"}
      />
      <label
        for={"cand-#{@id}"}
        class={["text-sm", if(@duplicate?, do: "text-slate-500 dark:text-slate-400", else: "text-slate-800 dark:text-slate-200")]}
      >
        {@label}
        <span :if={@duplicate?} class="ml-1 text-xs text-slate-500 dark:text-slate-400">
          ({gettext("already on your profile")})
        </span>
      </label>
    </li>
    """
  end

  @doc "A titled group of candidate rows, rendered only when the group is non-empty."
  attr(:title, :string, required: true)
  attr(:items, :list, required: true)
  slot(:inner_block, required: true)

  def candidate_section(assigns) do
    ~H"""
    <div :if={@items != []} class="mt-6" data-select-group>
      <.select_group_header title={@title} />
      <ul class="mt-2 divide-y divide-slate-100 dark:divide-slate-800">
        {render_slot(@inner_block)}
      </ul>
    </div>
    """
  end

  @doc """
  Section header for a group of selectable candidates: the title plus a
  "select all / deselect all" toggle. The toggle is a progressive enhancement
  (the `data-select-all` button in `app.js` reveals it and flips every checkbox
  inside the enclosing `[data-select-group]`), so it starts hidden and does
  nothing with JS off. It carries both labels so the JS can swap them without
  hardcoding a translated string.
  """
  attr(:title, :string, required: true)

  def select_group_header(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3">
      <.section_title>{@title}</.section_title>
      <button
        type="button"
        data-select-all
        data-label-select={gettext("Select all")}
        data-label-deselect={gettext("Unselect all")}
        class="hidden text-xs font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
      >
        {gettext("Select all")}
      </button>
    </div>
    """
  end

  embed_templates("../templates/import/*")
end
