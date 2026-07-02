defmodule VutuvWeb.ImportHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

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
    <div :if={@items != []} class="mt-6">
      <.section_title>{@title}</.section_title>
      <ul class="mt-2 divide-y divide-slate-100 dark:divide-slate-800">
        {render_slot(@inner_block)}
      </ul>
    </div>
    """
  end

  embed_templates("../templates/import/*")
end
