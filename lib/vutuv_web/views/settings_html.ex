defmodule VutuvWeb.SettingsHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../templates/settings/*")

  @doc """
  One row on the account hub: a title, an optional sub-line, and a right-aligned
  text link to where the thing is actually managed. Keeps the hub's lists tidy
  and DRY.
  """
  attr(:title, :string, required: true)
  attr(:subtitle, :string, default: nil)
  attr(:href, :string, required: true)
  attr(:label, :string, required: true)

  def account_row(assigns) do
    ~H"""
    <li class="flex items-center justify-between gap-4 py-3">
      <span class="min-w-0">
        <span class="block font-medium text-slate-900 dark:text-white">{@title}</span>
        <span :if={@subtitle} class="block truncate text-sm text-slate-600 dark:text-slate-400">
          {@subtitle}
        </span>
      </span>
      <.link
        navigate={@href}
        class="shrink-0 text-sm font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
      >
        {@label}
      </.link>
    </li>
    """
  end
end
