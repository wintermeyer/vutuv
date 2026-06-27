defmodule VutuvWeb.Admin.AdminHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../../templates/admin/admin/*")

  @doc """
  One tile on the admin dashboard: a section title (with an optional coral count
  badge), a one-line plain-language description, and a call-to-action link into
  the section. The dashboard is the only caller, so the component lives here and
  keeps every tile visually identical.
  """
  attr(:title, :string, required: true)
  attr(:href, :string, required: true)
  attr(:cta, :string, required: true)
  attr(:id, :string, default: nil)
  attr(:count, :integer, default: nil)
  slot(:inner_block, required: true)

  def admin_card(assigns) do
    ~H"""
    <section class="card">
      <div class="flex items-center justify-between gap-4">
        <h1 class="flex items-center gap-2">
          {@title}
          <.count_badge :if={@count} count={@count} />
        </h1>
        <a
          href={@href}
          id={@id}
          class="shrink-0 whitespace-nowrap text-sm font-semibold text-brand-600 hover:text-brand-700"
        >
          {@cta} ›
        </a>
      </div>
      <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
        {render_slot(@inner_block)}
      </p>
    </section>
    """
  end

  @doc """
  A labelled group of dashboard tiles. The uppercase heading clusters the tiles
  by what an admin comes to do (moderation, communication, content, system), so
  a new admin can scan the panel instead of reading every card.
  """
  attr(:title, :string, required: true)
  slot(:inner_block, required: true)

  def admin_group(assigns) do
    ~H"""
    <section>
      <.section_title>{@title}</.section_title>
      <div class="card-list mt-3">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end
end
