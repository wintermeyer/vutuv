---
paths:
  - "**/*.heex"
  - "assets/css/**"
  - "lib/vutuv_web/**"
---

## vutuv visual design system — "Direction A"

Every page must use this one visual language. It is "confident professional-bold":
deep heritage **blue** + a **coral** accent, white cards on a light grey canvas,
clean typography. **Dark mode follows the system** (`prefers-color-scheme`) — there
is **no theme toggle**, and every surface/text needs `dark:` variants.

### Two tracks — know which one you're touching

1. **Legacy controller+view pages** still use shared classes (`.card` / `.card-list`,
   `.editform` + inputs, `.button` + variants, `.breadcrumbs`, `.profile-header` page
   title, `.pure-table`, `.alert`, `.tags`/`.badges`). They are styled **centrally** in
   `assets/css/components.css`. **To restyle legacy pages, edit `components.css` — do
   NOT reskin per-template.** A new legacy page that reuses these classes gets the look
   for free.
2. **New / hand-written pages** (the shell `ShellLive`, the LiveViews, `user/show.html.heex`)
   use the **`VutuvWeb.UI` components** (see **Components** below) or, where no component
   fits, the **recipes** below. Prefer a component; fall back to a recipe. Reach for a
   green-field rewrite only when a page's UX needs rethinking (like the profile) —
   otherwise let track 1 handle it.

### Tokens (defined in `assets/css/app.css` `@theme`)

- **Brand blue:** `bg-brand-600` (primary), hover `bg-brand-700`; text `text-brand-700` / `text-brand-800`; tint `bg-brand-50`. Full scale `brand-50…900`.
- **Accent (unread counts / CTAs highlight):** `bg-accent` / `text-accent` (coral `#f97362`).
- **Surfaces:** page is grey (`slate-50`/`slate-100`); cards `bg-white`; borders `ring-slate-200`; text `text-slate-900 / 700 / 500 / 400`.
- **Dark:** `dark:bg-slate-900` (cards) / `slate-950` (page), `dark:ring-slate-800`, `dark:text-slate-100 / 300 / 400`.

### Canonical recipes (copy these exactly)

- **Page root:** `<main>` already gives `mx-auto max-w-6xl px-4`. A page's own wrapper is e.g. `py-6` (+ `grid gap-6 lg:grid-cols-3` for a content+rail layout). Don't add another `max-w`/`px` unless intentional.
- **Card:** `rounded-2xl bg-white p-6 shadow-sm ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800` — or `<.card>`.
- **Section title:** `text-sm font-semibold uppercase tracking-wide text-slate-500` — or `<.section_title>`.
- **Primary button:** `rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white hover:bg-brand-700`.
- **Secondary button:** `rounded-lg bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200`.
- **Text link / "Add" action:** `text-sm font-semibold text-brand-600 hover:text-brand-700`.
- **Input / select / textarea:** `w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm focus:border-brand-500 focus:outline-none dark:border-slate-700 dark:bg-slate-800 dark:text-slate-100`.
- **Skill/tag chip:** `inline-flex items-center gap-2 rounded-lg bg-brand-50 px-3 py-1.5 text-sm font-medium text-brand-700 dark:bg-brand-900/40 dark:text-brand-100` — or `<.chip>`.
- **Unread count badge:** small `rounded-full bg-accent px-1 text-[11px] font-bold text-white`; add `ring-2 ring-white dark:ring-slate-900` when it overlaps an icon or avatar.
- **Avatar:** `Vutuv.Avatar.display_url(user, :medium|:thumb)` in an `<img>`, `rounded-2xl` (tile) or `rounded-full` (list) + `object-cover`.

### Components (`VutuvWeb.UI` — imported everywhere; no explicit import needed)

`lib/vutuv_web/templates/user/show.html.heex` is the canonical example of the kit.

- `<.card class="…">…</.card>` — the card surface.
- `<.section_title>…</.section_title>` — uppercase muted heading inside a card.
- `<.section_header title={…} add_href={owner? && ~p"/…/new"} />` — card header row: section title + optional right-aligned "Add" link (falsy `add_href` hides it); for a custom action use the `:action` slot instead.
- `<.button>` — `primary` (default) or `variant="secondary|ghost|danger"`. Renders a link when given `navigate`/`patch`/`href` (add `method="post|delete"` for CSRF actions), else a `<button>` (set `type="submit"`). e.g. `<.button href={~p"/connections?#{…}"} method="post">Follow</.button>`.
- `<.avatar user={@user} size="xs|sm|md|lg" shape="circle|square" />` — resolves `Vutuv.Avatar`; or pass `src=`; falls back to a neutral placeholder if given neither.
- `<.chip>` — skill/tag chip; pass `navigate`/`href` to render it as a link.
- `<.count_badge count={n} class="…" />` — coral unread badge; renders nothing when 0; `class` positions it. Add `ring-2 ring-white dark:ring-slate-900` via `class` when it overlaps an icon/avatar (the shell does this).
- `<.input name=… label=… type=… value=… error=… />` — labelled input for hand-written **vertical** forms. Inline/pill inputs use the raw input recipe above. (Legacy controller forms are styled by `components.css` — leave their `.editform` markup.)

### Shell & layout facts (don't re-implement)

- The chrome — sticky top bar + mobile bottom tab bar with the live unread badges — is `VutuvWeb.ShellLive`, embedded in `app.html.heex`. Pages render **inside** it; never add their own nav.
- **Flash = top-right toasts** (`#toast-tray` in `app.html.heex`). Never add inline flash banners and never call `VutuvWeb.LayoutHTML.flash/1` (it is intentionally a no-op).
- In-app real-time events go through `Vutuv.Activity` (PubSub on `"user:<id>"`) and `VutuvWeb.Presence`.

### CSS architecture (don't break it)

`app.css` order: `@import "tailwindcss"` → `@import "./legacy.css" layer(components)` →
`@import "./components.css" layer(components)`, **all at the top** before `@source`/`@theme`.
Both legacy and the reskin live in the `components` layer so Tailwind utilities win and
legacy's `nav,section,header{display:block}` reset can't break the responsive shell. The
`@import … layer()` only works at the top — CSS ignores `@import` after other rules.
Dev serves `/assets/app.css` undigested, so hard-reload (Cmd+Shift+R) after a rebuild.

### Don'ts

- No theme toggle (dark = system).
- Don't reskin legacy pages per-template — edit `components.css`.
- Don't invent new bespoke colours; stay on brand / accent / slate.
- No em-dashes in UI copy (project-wide rule).
