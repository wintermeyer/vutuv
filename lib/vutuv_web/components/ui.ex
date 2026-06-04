defmodule VutuvWeb.UI do
  @moduledoc """
  Direction A design-system components — reuse these on hand-written pages so the
  visual language stays consistent and DRY. See `.claude/rules/design.md` for the
  full spec and raw-utility recipes. Legacy controller pages are styled centrally
  in `assets/css/components.css`, not here.

  Imported into every HTML view and LiveView via `VutuvWeb` (`html`, `live_view`,
  `live_component`), so all of these are available everywhere with no explicit
  import: `<.card>`, `<.section_title>`, `<.section_header>`, `<.chip>`,
  `<.button>`, `<.avatar>`, `<.count_badge>`, `<.input>`.
  """
  use Phoenix.Component
  use Gettext, backend: VutuvWeb.Gettext

  @doc "The Direction A card surface (white, rounded, ring, soft shadow; dark-aware)."
  attr(:class, :string, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def card(assigns) do
    ~H"""
    <section
      class={[
        "rounded-2xl bg-white p-6 shadow-sm ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc "Uppercase muted section heading used inside cards."
  attr(:class, :string, default: nil)
  slot(:inner_block, required: true)

  def section_title(assigns) do
    ~H"""
    <h2 class={["text-sm font-semibold uppercase tracking-wide text-slate-500", @class]}>
      {render_slot(@inner_block)}
    </h2>
    """
  end

  @doc """
  Card header row: a `<.section_title>` with an optional right-aligned action.
  Pass `add_href` for the canonical "Add" link (a falsy value hides it, so
  `add_href={owner? && ~p"/…/new"}` reads naturally), or use the `:action` slot
  for a custom action.
  """
  attr(:title, :string, required: true)
  attr(:add_href, :any, default: nil)
  slot(:action)

  def section_header(assigns) do
    ~H"""
    <div class="mb-4 flex items-center justify-between">
      <.section_title>{@title}</.section_title>
      <.link :if={@add_href} href={@add_href} class="text-sm font-semibold text-brand-600 hover:text-brand-700">
        {gettext("Add")}
      </.link>
      {render_slot(@action)}
    </div>
    """
  end

  @doc "Skill/tag chip (brand tint). Pass `navigate`/`href` to render it as a link."
  attr(:navigate, :string, default: nil)
  attr(:href, :string, default: nil)
  attr(:class, :string, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def chip(assigns) do
    ~H"""
    <.link
      :if={@navigate || @href}
      navigate={@navigate}
      href={@href}
      class={[chip_class(), "hover:bg-brand-100", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    <span :if={!(@navigate || @href)} class={[chip_class(), @class]} {@rest}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp chip_class,
    do:
      "inline-flex items-center gap-2 rounded-lg bg-brand-50 px-3 py-1.5 text-sm font-medium text-brand-700 dark:bg-brand-900/40 dark:text-brand-100"

  @doc """
  Button. Renders a `<.link>` when given `navigate`/`patch`/`href` (with optional
  `method` for POST/DELETE actions), otherwise a `<button>` (set `type`). Variants:
  `primary` (default), `secondary`, `ghost`, `danger`.
  """
  attr(:variant, :string, default: "primary", values: ~w(primary secondary ghost danger))
  attr(:navigate, :string, default: nil)
  attr(:patch, :string, default: nil)
  attr(:href, :string, default: nil)
  attr(:method, :string, default: nil)
  attr(:type, :string, default: nil)
  attr(:class, :string, default: nil)

  attr(:rest, :global,
    include: ~w(download name value disabled form title phx-click phx-value-id phx-disable-with)
  )

  slot(:inner_block, required: true)

  def button(assigns) do
    ~H"""
    <.link
      :if={@navigate || @patch || @href}
      navigate={@navigate}
      patch={@patch}
      href={@href}
      method={@method}
      class={[button_class(@variant), @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    <button
      :if={!(@navigate || @patch || @href)}
      type={@type || "button"}
      class={[button_class(@variant), @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @button_base "inline-flex items-center justify-center gap-1.5 rounded-lg px-4 py-2 text-sm font-semibold"
  defp button_class("secondary"),
    do:
      "#{@button_base} bg-slate-100 text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200"

  defp button_class("ghost"),
    do:
      "#{@button_base} text-brand-600 hover:bg-brand-50 hover:text-brand-700 dark:hover:bg-slate-800"

  defp button_class("danger"), do: "#{@button_base} bg-red-600 text-white hover:bg-red-700"
  defp button_class(_), do: "#{@button_base} bg-brand-600 text-white hover:bg-brand-700"

  @doc """
  User avatar. Pass `user` (a `%Vutuv.Accounts.User{}`, resolved via `Vutuv.Avatar`)
  or a raw `src`. Sizes `xs|sm|md|lg`; `shape` `circle` (default) or `square`.
  """
  attr(:user, :any, default: nil)
  attr(:src, :string, default: nil)
  attr(:alt, :string, default: "")
  attr(:size, :string, default: "md", values: ~w(xs sm md lg))
  attr(:shape, :string, default: "circle", values: ~w(circle square))
  attr(:class, :string, default: nil)

  # Neutral placeholder so a call with neither `user` nor `src` still renders a
  # valid <img> instead of a broken one.
  @fallback_avatar "data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%20viewBox='0%200%2024%2024'%3E%3Crect%20width='24'%20height='24'%20fill='%23e2e8f0'/%3E%3Ccircle%20cx='12'%20cy='9'%20r='4'%20fill='%2394a3b8'/%3E%3Cpath%20d='M4%2022c0-4%204-6%208-6s8%202%208%206'%20fill='%2394a3b8'/%3E%3C/svg%3E"

  def avatar(assigns) do
    src =
      assigns.src ||
        (assigns.user && Vutuv.Avatar.display_url(assigns.user, avatar_url_size(assigns.size))) ||
        @fallback_avatar

    assigns = assign(assigns, :resolved_src, src)

    ~H"""
    <img
      src={@resolved_src}
      alt={@alt}
      class={[
        avatar_size(@size),
        if(@shape == "square", do: "rounded-2xl", else: "rounded-full"),
        "object-cover",
        @class
      ]}
    />
    """
  end

  defp avatar_size("xs"), do: "h-8 w-8"
  defp avatar_size("sm"), do: "h-9 w-9"
  defp avatar_size("lg"), do: "h-24 w-24"
  defp avatar_size(_), do: "h-12 w-12"

  defp avatar_url_size(size) when size in ["xs", "sm"], do: :thumb
  defp avatar_url_size(_), do: :medium

  @doc "Coral unread-count badge. Renders nothing when `count` is 0. Pass `class` to position it."
  attr(:count, :integer, default: 0)
  attr(:class, :string, default: nil)

  def count_badge(assigns) do
    ~H"""
    <span
      :if={@count > 0}
      class={[
        "inline-flex h-[18px] min-w-[18px] items-center justify-center rounded-full bg-accent px-1 text-[11px] font-bold text-white",
        @class
      ]}
    >
      {@count}
    </span>
    """
  end

  @doc "Labelled text input for hand-written forms (legacy forms are styled by components.css)."
  attr(:name, :string, required: true)
  attr(:type, :string, default: "text")
  attr(:label, :string, default: nil)
  attr(:value, :string, default: nil)
  attr(:error, :string, default: nil)
  attr(:class, :string, default: nil)

  attr(:rest, :global,
    include:
      ~w(id placeholder required autofocus autocomplete readonly disabled min max step inputmode)
  )

  def input(assigns) do
    ~H"""
    <div>
      <label :if={@label} class="mb-1.5 block text-sm font-medium text-slate-700 dark:text-slate-300">
        {@label}
      </label>
      <input
        type={@type}
        name={@name}
        value={@value}
        class={[
          "w-full rounded-lg border bg-white px-3 py-2 text-sm text-slate-900 focus:border-brand-500 focus:outline-none dark:bg-slate-800 dark:text-slate-100",
          if(@error, do: "border-red-400", else: "border-slate-300 dark:border-slate-700"),
          @class
        ]}
        {@rest}
      />
      <p :if={@error} class="mt-1 text-xs text-red-600">{@error}</p>
    </div>
    """
  end
end
