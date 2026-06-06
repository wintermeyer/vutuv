defmodule VutuvWeb.UI do
  @moduledoc """
  Direction A design-system components — reuse these on hand-written pages so the
  visual language stays consistent and DRY. See `.claude/rules/design.md` for the
  full spec and raw-utility recipes. Legacy controller pages are styled centrally
  in `assets/css/components.css`, not here.

  Imported into every HTML view and LiveView via `VutuvWeb` (`html`, `live_view`,
  `live_component`), so all of these are available everywhere with no explicit
  import: `<.card>`, `<.section_title>`, `<.section_header>`, `<.card_menu>`,
  `<.chip>`, `<.button>`, `<.avatar>`, `<.count_badge>`, `<.input>`, `<.pager>`.
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
  Card header row: a `<.section_title>` with optional right-aligned actions.
  Pass `add_href` for the canonical "Add" link (a falsy value hides it, so
  `add_href={owner? && ~p"/…/new"}` reads naturally), and/or use the `:action`
  slot for a custom action; multiple actions sit together in one group.
  """
  attr(:title, :string, required: true)
  attr(:add_href, :any, default: nil)
  slot(:action)

  def section_header(assigns) do
    ~H"""
    <div class="mb-4 flex items-center justify-between">
      <.section_title>{@title}</.section_title>
      <div class="flex items-center gap-2">
        <.link :if={@add_href} href={@add_href} class="text-sm font-semibold text-brand-600 hover:text-brand-700">
          {gettext("Add")}
        </.link>
        {render_slot(@action)}
      </div>
    </div>
    """
  end

  @doc """
  Per-card ⋯ menu for hand-written (Track 2) profile sections — the quiet
  home for the owner's rare actions (add entry, manage entries) so they are
  not always in the viewer's face. A native `<details data-menu>` dropdown:
  no JS framework, keyboard-accessible out of the box; `app.js` closes any
  open menu on outside click and Escape. Items render via the `:item` slot
  (`href` required, optional `method`); the owner guard stays at the call
  site, e.g. inside `<.section_header>`'s `:action` slot:

      <:action :if={owner?}>
        <.card_menu id="profile-links-menu">
          <:item href={~p"/…/new"}>{gettext("Add entry")}</:item>
          <:item href={~p"/…"}>{gettext("Manage entries")}</:item>
        </.card_menu>
      </:action>

  Profile-section deletion intentionally does not live here — the manage
  pages carry per-row edit/delete and every edit form has
  `<.form_actions delete_to={…} />`. The post card's author menu is the
  exception: its Delete item (`method="delete"` + `confirm` + `danger`)
  is the post's primary delete affordance.
  """
  attr(:id, :string, required: true)

  slot :item, required: true do
    attr(:href, :any, required: true)
    attr(:method, :string)
    attr(:confirm, :string, doc: "data-confirm prompt for destructive items")
    attr(:danger, :boolean, doc: "style the item red")
  end

  def card_menu(assigns) do
    ~H"""
    <details data-menu class="relative" id={@id}>
      <summary
        title={gettext("Options")}
        class={[
          "flex h-7 w-7 cursor-pointer list-none items-center justify-center rounded-full text-slate-400",
          "hover:bg-slate-100 hover:text-slate-600 dark:hover:bg-slate-800 dark:hover:text-slate-300",
          "[&::-webkit-details-marker]:hidden"
        ]}
      >
        <svg class="h-5 w-5" fill="currentColor" viewBox="0 0 24 24" aria-hidden="true">
          <path d="M6.75 12a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0Zm6.75 0a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0Zm6.75 0a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0Z" />
        </svg>
        <span class="sr-only">{gettext("Options")}</span>
      </summary>
      <div class="absolute right-0 z-20 mt-1 w-52 rounded-xl bg-white py-1 shadow-lg ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-700">
        <.link
          :for={item <- @item}
          href={item.href}
          method={item[:method]}
          data-confirm={item[:confirm]}
          class={[
            "block px-4 py-2 text-sm font-medium",
            if(item[:danger],
              do: "text-red-600 hover:bg-red-50 dark:text-red-400 dark:hover:bg-red-950/40",
              else: "text-slate-700 hover:bg-slate-50 dark:text-slate-200 dark:hover:bg-slate-800"
            )
          ]}
        >
          {render_slot(item)}
        </.link>
      </div>
    </details>
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

  @doc """
  Compact display form for counted numbers, used site-wide wherever a count is
  shown: exact up to 999, then `1K`, `80K`, `5M`, `2B`. Floored, so a count is
  never overstated ("1K" means at least a thousand).
  """
  def compact_count(n) when is_integer(n) and n >= 1_000_000_000,
    do: "#{div(n, 1_000_000_000)}B"

  def compact_count(n) when is_integer(n) and n >= 1_000_000, do: "#{div(n, 1_000_000)}M"
  def compact_count(n) when is_integer(n) and n >= 1_000, do: "#{div(n, 1_000)}K"
  def compact_count(n), do: to_string(n)

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
      {compact_count(@count)}
    </span>
    """
  end

  @doc """
  Numbered pagination for offset-paginated browse pages (followers, tags,
  users). Pass the conn params (for the current `?page`) and the total row
  count; page size and windowing come from `Vutuv.Pages`. Renders nothing
  when one page fits everything. Feed pages use a "Load more" button instead.
  """
  attr(:params, :map, required: true)
  attr(:total, :integer, required: true)

  def pager(assigns) do
    total_pages = Vutuv.Pages.total_pages(assigns.total)
    current = Vutuv.Pages.effective_page(assigns.params, assigns.total)
    window = Enum.filter((current - 5)..(current + 5), &(&1 in 1..total_pages))

    assigns =
      assigns
      |> assign(:total_pages, total_pages)
      |> assign(:current, current)
      |> assign(:window, window)

    ~H"""
    <nav
      :if={@total_pages > 1}
      aria-label={gettext("Pagination")}
      class="mt-6 flex items-center justify-center gap-1 text-sm font-semibold"
    >
      <span :if={List.first(@window) > 1} class="px-1 text-slate-400">…</span>
      <%= for num <- @window do %>
        <%= if num == @current do %>
          <span
            aria-current="page"
            class="flex h-9 min-w-9 items-center justify-center rounded-lg bg-brand-600 px-2 text-white"
          >
            {num}
          </span>
        <% else %>
          <a
            href={"?page=#{num}"}
            class="flex h-9 min-w-9 items-center justify-center rounded-lg px-2 text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-800"
          >
            {num}
          </a>
        <% end %>
      <% end %>
      <span :if={List.last(@window) < @total_pages} class="px-1 text-slate-400">…</span>
    </nav>
    """
  end

  @doc """
  Legacy (Track 1) page top shared by the controller pages: the `.profile-header`
  h1 block and/or the `.breadcrumbs` row. This is the boilerplate that opened ~47
  page templates (and the breadcrumbs row ~65). Styled by `components.css`, not
  Tailwind — do not swap in utilities.

  Pass `title` to render the `<div class="profile-header"><div class="profile-header__info"><h1>…</h1></div></div>`
  block (the title is a plain string the call site already builds, e.g.
  `gettext("Emails belonging to ") <> full_name(@user)` or
  `gettext("Tags of %{name}", name: full_name(@user))`); omit it on the new/edit
  pages that only carry breadcrumbs. Pass `crumbs` (the list you used to hand to
  `gen_breadcrumbs/1`) to render the `.breadcrumbs` row; `gen_breadcrumbs/1` is
  called **fully qualified** here because `VutuvWeb.UI` does not import
  `UserHelpers`. Pages whose header carries more than the single h1 (avatar,
  buttons, …) keep their hand-written markup.

  Use it as `<.page_header title={…} crumbs={[gettext("Users"), {full_name(@user), ~p"/…"}, gettext("Emails")]} />`.
  """
  attr(:title, :string, default: nil)
  attr(:crumbs, :list, default: nil)

  def page_header(assigns) do
    ~H"""
    <div :if={@title} class="profile-header">
      <div class="profile-header__info">
        <h1>{@title}</h1>
      </div>
    </div>
    <div :if={@crumbs} class="breadcrumbs">
      {VutuvWeb.UserHelpers.gen_breadcrumbs(@crumbs)}
    </div>
    """
  end

  @doc """
  Legacy (Track 1) changeset-error banner shared by the `editform` `form_content`
  templates. Renders the `.alert.alert-danger` row only when `@changeset.action`
  is set (a failed submit), nothing on a fresh form. Styled by `components.css`,
  not Tailwind — do not swap in utilities. Use it as `<.form_error changeset={@changeset} />`.
  """
  attr(:changeset, :any, required: true)

  def form_error(assigns) do
    ~H"""
    <div :if={@changeset.action} class="alert alert-danger">
      <p class="editform__error">{gettext("Oops, something went wrong! Please check the errors below.")}</p>
    </div>
    """
  end

  @doc """
  Legacy (Track 1) Cancel/Submit actions row shared by the `editform`
  `form_content` templates. Emits the same `.editform__actions` markup the
  `link/2` + `submit/2` helpers produced (a `.button.button--cancel` link to
  `@backlink` and a `.button` submit button), styled by `components.css`. Use it
  as `<.form_actions backlink={@backlink} />`. Forms with a custom submit label
  or no Cancel keep their hand-written row.

  Pass `delete_to` on **edit** forms to append the canonical delete control
  (`id="delete-entry"`, a `.button--danger` link sending a CSRF-protected
  DELETE behind a `data-confirm` prompt) — deletion lives on the edit form,
  one deliberate step away from the profile. The shared `form_content`
  templates thread it through as `delete_to={assigns[:delete_to]}` so the
  new-forms render without it.
  """
  attr(:backlink, :string, required: true)
  attr(:delete_to, :any, default: nil)
  attr(:confirm, :string, default: nil)

  def form_actions(assigns) do
    ~H"""
    <div class="editform__actions">
      <a class="button button--cancel" href={@backlink}>{gettext("Cancel")}</a>
      <button class="button" type="submit">{gettext("Submit")}</button>
      <.link
        :if={@delete_to}
        id="delete-entry"
        href={@delete_to}
        method="delete"
        data-confirm={@confirm || gettext("Are you sure?")}
        class="button button--danger"
      >
        {gettext("Delete entry")}
      </.link>
    </div>
    """
  end

  @doc """
  Legacy (Track 1) edit/delete (and optional view) icon-button group. Renders the
  canonical legacy anatomy from `design.md`: a `.btns-right` wrapper holding
  `.button.button--icon.button--small` controls with CSS-glyph icons
  (`i.icon.icon--edit|--delete|--search`), in **view → edit → delete** source
  order. Delete is rendered through Phoenix's `delete` method (so the
  `phoenix_html` JS issues a CSRF-protected DELETE, the same way the legacy
  `button to:, method: :delete` did) and additionally carries `button--danger`.

  Each control is optional — omit `edit_to`/`delete_to`/`show_to` to skip that
  button. The guard (`same_user?/2`, admin scoping, …) stays at the **call site**;
  this component is purely presentational. Pass `confirm` for a delete
  `data-confirm` prompt, `title_*` for tooltips, `class` for extra wrapper
  classes, and the optional `:extra` slot for a bespoke trailing button.

  Use it as e.g.
  `<.edit_delete_actions edit_to={~p"/…/edit"} delete_to={~p"/…"} confirm={gettext("Are you sure?")} />`.
  """
  attr(:show_to, :string, default: nil)
  attr(:edit_to, :string, default: nil)
  attr(:delete_to, :string, default: nil)
  attr(:confirm, :string, default: nil)
  attr(:title_show, :string, default: nil)
  attr(:title_edit, :string, default: nil)
  attr(:title_delete, :string, default: nil)
  attr(:class, :any, default: nil)
  slot(:extra)

  def edit_delete_actions(assigns) do
    assigns = assign(assigns, :wrapper_class, String.trim("btns-right #{assigns.class}"))

    ~H"""
    <div class={@wrapper_class}>
      <.link :if={@show_to} href={@show_to} title={@title_show} class="button button--icon button--small">
        <i class="icon icon--search"></i>
      </.link>
      <.link :if={@edit_to} href={@edit_to} title={@title_edit} class="button button--icon button--small">
        <i class="icon icon--edit"></i>
      </.link>
      <.link
        :if={@delete_to}
        href={@delete_to}
        method="delete"
        data-confirm={@confirm}
        title={@title_delete}
        class="button button--icon button--small button--danger"
      >
        <i class="icon icon--delete"></i>
      </.link>
      {render_slot(@extra)}
    </div>
    """
  end

  @doc """
  Legacy (Track 1) card shell shared by the owned-resource index pages and the
  new/edit form wrappers: the `<div class="card-list"><section class="card">…</section></div>`
  boilerplate that used to be copy-pasted into ~30 templates, styled by
  `components.css` (not Tailwind — do not swap in utilities). The `inner_block`
  goes inside the `.card`.

  Pass `add_href` for the canonical owner "Add" link (a `.card__morelink`; a falsy
  value hides it, so `add_href={same_user?(@user, @current_user) && ~p"/…/new"}`
  reads naturally), `add_label` to override its text. Set `empty` to render the
  `<p class="card__empty">` empty-state line (text from `empty_text`) **instead of**
  the inner block. Use it as `<.card_section empty={…} add_href={…}>…</.card_section>`.
  """
  attr(:add_href, :any, default: nil)
  attr(:add_label, :string, default: nil)
  attr(:empty, :boolean, default: false)
  attr(:empty_text, :string, default: nil)
  slot(:inner_block, required: true)

  def card_section(assigns) do
    ~H"""
    <div class="card-list">
      <section class="card">
        <%= if @empty do %>
          <p class="card__empty">{@empty_text || gettext("Nothing here yet.")}</p>
        <% else %>
          {render_slot(@inner_block)}
        <% end %>
        <.link :if={@add_href} href={@add_href} class="card__morelink">
          {@add_label || gettext("Add")}
        </.link>
      </section>
    </div>
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
