defmodule VutuvWeb.Admin.AdminHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../../templates/admin/admin/*")

  @doc """
  One tile on the admin dashboard. The whole tile is the link into its section
  (a big, satisfying target that lifts on hover); a tinted icon square anchors it
  visually, a plain-language line says what it does, and a call-to-action with a
  sliding arrow sits at the foot.

  Tiles read their own urgency. When `attention` is set (there is pending work)
  the icon square and the count pill turn coral and the ring picks up the accent,
  so the cards that need an admin jump out of the grid; calm tiles stay
  blue-tinted. `count` renders as a pill only when it is greater than zero.
  """
  attr(:icon, :string, required: true)
  attr(:title, :string, required: true)
  attr(:href, :string, required: true)
  attr(:cta, :string, required: true)
  attr(:id, :string, default: nil)
  attr(:count, :integer, default: nil)

  attr(:count_exact, :boolean,
    default: false,
    doc: "show the count grouped in full (60.023) instead of compact (60K)"
  )

  attr(:attention, :boolean, default: false)
  slot(:inner_block, required: true)

  def admin_card(assigns) do
    ~H"""
    <.link
      href={@href}
      id={@id}
      class={[
        "group flex h-full flex-col gap-4 rounded-2xl bg-white p-5 shadow-sm ring-1 transition duration-200 hover:-translate-y-0.5 hover:shadow-md dark:bg-slate-900",
        @attention && "ring-accent/40 hover:ring-accent/70 dark:ring-accent/40",
        !@attention &&
          "ring-slate-200 hover:ring-brand-200 dark:ring-slate-800 dark:hover:ring-brand-700"
      ]}
    >
      <div class="flex items-start justify-between">
        <span class={[
          "flex h-11 w-11 items-center justify-center rounded-xl transition",
          @attention && "bg-accent/10 text-accent",
          !@attention &&
            "bg-brand-50 text-brand-700 group-hover:bg-brand-100 dark:bg-brand-900/40 dark:text-brand-200 dark:group-hover:bg-brand-900/70"
        ]}>
          <.section_icon name={@icon} />
        </span>

        <span
          :if={@count && @count > 0}
          class={[
            "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-bold tabular-nums",
            @attention && "bg-accent text-white",
            !@attention && "bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-300"
          ]}
        >
          {if @count_exact, do: delimited_count(@count), else: compact_count(@count)}
        </span>
      </div>

      <div class="flex flex-1 flex-col">
        <h2 class="text-base font-bold text-slate-900 dark:text-slate-100">{@title}</h2>
        <p class="mt-1 text-sm leading-relaxed text-slate-600 dark:text-slate-400">
          {render_slot(@inner_block)}
        </p>
      </div>

      <span class="mt-auto inline-flex items-center gap-1.5 text-sm font-semibold text-brand-700 dark:text-brand-400">
        {@cta}
        <svg
          class="h-4 w-4 transition-transform duration-200 group-hover:translate-x-1"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <path d="M5 12h14M13 6l6 6-6 6" />
        </svg>
      </span>
    </.link>
    """
  end

  @doc """
  A labelled group of dashboard tiles, laid out as a responsive grid. The
  uppercase heading clusters the tiles by what an admin comes to do (moderation,
  communication, content, system), so a new admin can scan the panel instead of
  reading every card.
  """
  attr(:title, :string, required: true)
  slot(:inner_block, required: true)

  def admin_group(assigns) do
    ~H"""
    <section>
      <h2 class="text-xs font-bold uppercase tracking-wider text-slate-500 dark:text-slate-400">
        {@title}
      </h2>
      <div class="mt-3 grid gap-4 sm:grid-cols-2">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  # The per-section glyphs. Hand-drawn outline icons (24px grid, 1.6 stroke) kept
  # local to the admin dashboard, the one place that needs this set; they follow
  # the same outline language as the VutuvWeb.UI SVG icons.
  attr(:name, :string, required: true)

  defp section_icon(assigns) do
    ~H"""
    <svg
      class="h-6 w-6"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.6"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <%= case @name do %>
        <% "shield" -> %>
          <path d="M12 3 5 6v5.2c0 4.3 2.9 7.4 7 8.8 4.1-1.4 7-4.5 7-8.8V6l-7-3Z" />
          <path d="m9 11.8 2 2 4-4" />
        <% "users" -> %>
          <circle cx="9" cy="8" r="3.2" />
          <path d="M3.5 19.2a5.5 5.5 0 0 1 11 0" />
          <path d="M15.6 5.1a3.2 3.2 0 0 1 0 6" />
          <path d="M16.8 13.3a5.5 5.5 0 0 1 4 5.9" />
        <% "envelope" -> %>
          <rect x="3" y="5.5" width="18" height="13" rx="2" />
          <path d="m4 7.5 8 5.2 8-5.2" />
        <% "paper-plane" -> %>
          <path d="M21 3 3 10.4l6.6 2.6L12 20l3-6.2L21 3Z" />
          <path d="m9.6 13 5.4-5.6" />
        <% "funnel" -> %>
          <path d="M3 4.5h18l-7 8.2V19l-4 2v-8.3L3 4.5Z" />
        <% "tag" -> %>
          <path d="M3.5 11.2V4.8a1.3 1.3 0 0 1 1.3-1.3h6.4c.35 0 .68.14.92.38l8 8a1.3 1.3 0 0 1 0 1.84l-6.4 6.4a1.3 1.3 0 0 1-1.84 0l-8-8a1.3 1.3 0 0 1-.38-.92Z" />
          <circle cx="7.6" cy="7.6" r="1.3" />
        <% "medal" -> %>
          <path d="M8.5 3.5 12 9l3.5-5.5" />
          <circle cx="12" cy="15" r="6" />
          <path d="m9.4 15 1.8 1.8 3.4-3.6" />
        <% "at" -> %>
          <circle cx="12" cy="12" r="3.6" />
          <path d="M15.6 8.4v4.8a2.4 2.4 0 0 0 4.8 0V12a8.4 8.4 0 1 0-3.3 6.7" />
        <% "globe" -> %>
          <circle cx="12" cy="12" r="8.5" />
          <path d="M3.5 12h17" />
          <path d="M12 3.5c2.3 2.3 3.7 5.3 3.7 8.5s-1.4 6.2-3.7 8.5c-2.3-2.3-3.7-5.3-3.7-8.5S9.7 5.8 12 3.5Z" />
        <% "chart" -> %>
          <path d="M4 4v16h16" />
          <rect x="6.6" y="13" width="2.6" height="4" rx=".5" />
          <rect x="11" y="9" width="2.6" height="8" rx=".5" />
          <rect x="15.4" y="6" width="2.6" height="11" rx=".5" />
        <% "key" -> %>
          <circle cx="8.5" cy="14.5" r="3.5" />
          <path d="M11 12 19 4" />
          <path d="m16 7 2.5 2.5" />
          <path d="m19 4 1.6 1.6" />
        <% "megaphone" -> %>
          <path d="M4 9.5v5a1 1 0 0 0 1 1h2.6l8 4.4V4.1l-8 4.4H5a1 1 0 0 0-1 1Z" />
          <path d="M18 9.6a3.5 3.5 0 0 1 0 4.8" />
        <% "scale" -> %>
          <path d="M12 3v18" />
          <path d="M4 7h16" />
          <path d="m7 7-3 7a3 3 0 0 0 6 0L7 7Z" />
          <path d="m17 7-3 7a3 3 0 0 0 6 0l-3-7Z" />
          <path d="M8 21h8" />
        <% "sliders" -> %>
          <path d="M4 7h10" />
          <path d="M18 7h2" />
          <circle cx="16" cy="7" r="2" />
          <path d="M4 12h4" />
          <path d="M12 12h8" />
          <circle cx="10" cy="12" r="2" />
          <path d="M4 17h10" />
          <path d="M18 17h2" />
          <circle cx="16" cy="17" r="2" />
        <% "trash" -> %>
          <path d="M4 6.5h16" />
          <path d="M9 6.5V4.8a1.3 1.3 0 0 1 1.3-1.3h3.4A1.3 1.3 0 0 1 15 4.8v1.7" />
          <path d="M6 6.5 6.8 19a1.5 1.5 0 0 0 1.5 1.4h7.4a1.5 1.5 0 0 0 1.5-1.4L18 6.5" />
          <path d="M10 10.5v6" />
          <path d="M14 10.5v6" />
        <% "image" -> %>
          <rect x="3.5" y="5" width="17" height="14" rx="2" />
          <circle cx="9" cy="10" r="1.6" />
          <path d="m5 18 4.5-4.5 3 3L16 12l3.5 3.5" />
      <% end %>
    </svg>
    """
  end
end
