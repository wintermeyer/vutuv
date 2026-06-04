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
   title, `.pure-table`, `.alert`, `.tags`/`.badges`, `.search-form`, `.imagebox`,
   `.profiles`, `.job`, `section.jobs`, `ol.tags`/`.upvote`, `ul.thumbs`, `.ad`,
   `.card__empty` empty-state line, `.error-page` 404/403/500 card). They
   are styled **centrally** in `assets/css/components.css` — since the old vendored
   `legacy.css` was removed, that file is the **single source** for these classes,
   including element defaults (body canvas, h1/p/a, label, tables, dl) and the data-URI
   icons. **To restyle legacy pages, edit `components.css` — do NOT reskin
   per-template.** A new legacy page that reuses these classes gets the look for free.
   **Dark mode for all of it lives in the `@media (prefers-color-scheme: dark)` block
   at the end of `components.css`** — when you add a light rule with a hardcoded
   colour, add its dark counterpart there. `test/vutuv_web/dark_mode_css_test.exs`
   guards the canvas rule and that `legacy.css` stays deleted.
2. **New / hand-written pages** (the shell `ShellLive`, the LiveViews, `user/show.html.heex`)
   use the **`VutuvWeb.UI` components** (see **Components** below) or, where no component
   fits, the **recipes** below. Prefer a component; fall back to a recipe. Reach for a
   green-field rewrite only when a page's UX needs rethinking (like the profile) —
   otherwise let track 1 handle it.

### Tokens (defined in `assets/css/app.css` `@theme`)

- **Brand blue:** `bg-brand-600` (primary), hover `bg-brand-700`; text `text-brand-700` / `text-brand-800`; tint `bg-brand-50`. Full scale `brand-50…900`.
- **Accent (unread counts / CTAs highlight):** `bg-accent` / `text-accent` (coral `#f97362`).
- **Surfaces:** page is grey (`slate-50`/`slate-100`); cards `bg-white`; borders `ring-slate-200`; text `text-slate-900 / 700 / 500 / 400`.
- **Dark:** `dark:bg-slate-900` (cards) / `slate-950` (page), `dark:ring-slate-800`, `dark:text-slate-100 / 300 / 400`. `app.css` sets `html { color-scheme: light dark }` and `root.html.heex` ships a `theme-color` meta per scheme (`#ffffff` / `#020617`).

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
- `compact_count/1` — **every rendered count goes through this** (plain function, same module): exact up to 999, above that floored to `1K` / `80K` / `5M`. `<.count_badge>` applies it already; call it yourself for inline numbers (follower counts, member counter, "Load N of M more"). Page-number links in `<.pager>` are navigation, not counts — they stay exact.
- `<.input name=… label=… type=… value=… error=… />` — labelled input for hand-written **vertical** forms. Inline/pill inputs use the raw input recipe above. (Legacy controller forms are styled by `components.css` — leave their `.editform` markup.)
- `<.page_header title={…} crumbs={[…]} />` — **legacy Track 1** page top: the `.profile-header > .profile-header__info > h1` block (rendered when `title` is set) and/or the `.breadcrumbs` row wrapping `gen_breadcrumbs/1` (rendered when `crumbs` is set). `title` is a plain string the call site already builds (e.g. `gettext("Emails belonging to ") <> full_name(@user)` or `gettext("Tags of %{name}", name: full_name(@user))`); `crumbs` is the list you used to hand to `gen_breadcrumbs/1` (`gen_breadcrumbs/1` is called fully qualified inside the component because `VutuvWeb.UI` doesn't import `UserHelpers`). new/edit pages pass only `crumbs`. Replaces the ~47 header + ~65 breadcrumb boilerplate blocks across the controller pages. Pages whose header carries more than the single h1 (avatar, buttons, …) keep their hand-written markup; `user/show.html.heex`'s bespoke profile header is excluded.
- `<.form_error changeset={@changeset} />` — **legacy Track 1** changeset-error banner (`.alert.alert-danger` + `.editform__error`, styled by `components.css`, not utilities); renders only when `@changeset.action` is set. Shared by the `editform` `form_content` templates so the banner is written once.
- `<.form_actions backlink={@backlink} />` — **legacy Track 1** Cancel/Submit actions row (`.editform__actions` with a `.button.button--cancel` Cancel link to `@backlink` and a `.button` Submit). Shared by the `editform` `form_content` templates. Forms with a custom submit label or no Cancel keep their own hand-written row.
- `<.edit_delete_actions edit_to=… delete_to=… show_to=… confirm=… class=… />` — **legacy Track 1** edit/delete (optional view) icon-button group: the canonical `.btns-right` wrapper + `.button.button--icon.button--small` controls with CSS-glyph icons (`i.icon.icon--edit|--delete|--search`), in view → edit → delete order, delete via the `delete` method (CSRF) + `button--danger`. Each `*_to` is optional (omit to skip that button); `title_show/edit/delete` set tooltips, the `:extra` slot adds a bespoke trailing button. Keep the owner/admin guard at the call site. Replaces the ~16 hand-written pairs across the profile card_lists/shows and the group/job_posting/admin index tables.
- `<.card_section empty={…} add_href={…} add_label={…} empty_text={…}>…</.card_section>` — **legacy Track 1** card shell: the `<div class="card-list"><section class="card">…</section></div>` boilerplate that wrapped the owned-resource index pages and the new/edit form wrappers (styled by `components.css`, not utilities). The inner block goes inside the `.card`. `add_href` renders the owner "Add" link (`.card__morelink`; falsy hides it, so `add_href={same_user?(@user, @current_user) && ~p"/…/new"}`), `add_label` overrides its text. `empty={true}` renders the `<p class="card__empty">` empty-state line (text from `empty_text`, default gettext("Nothing here yet.")) **instead of** the inner block. Replaces the ~30 copy-pasted shells across the email/phone_number/url/social_media_account/work_experience/group/search_term indexes and the email/phone_number/url/social_media_account/work_experience/address/user/user_tag/job_posting/job_posting_tag/admin coupon|exonym|tag new+edit wrappers.
- `<.pager params={@conn.params} total={@row_count} />` — numbered pagination for offset-paginated **browse** pages (followers, tags, users); the math lives in `Vutuv.Pages` (`paginate/3` on the query, 250/page). Renders nothing when one page fits. **Feed** LiveViews (notifications) paginate with a cursor + "Load more" button appended into the stream instead (`Vutuv.Activity.notifications_page/2`) — don't mix the two styles.

### Shell & layout facts (don't re-implement)

- The chrome — sticky top bar + mobile bottom tab bar with the live unread badges — is `VutuvWeb.ShellLive`, embedded in `app.html.heex`. Pages render **inside** it; never add their own nav.
- **Flash = top-right toasts** (`#toast-tray` in `app.html.heex`). Never add inline flash banners; `VutuvWeb.LayoutHTML.flash/1` and its empty partial were deleted along with the last inline calls.
- In-app real-time events go through `Vutuv.Activity` (PubSub on `"user:<id>"`) and `VutuvWeb.Presence`.
- **Gettext locale must be set per process.** `VutuvWeb.Plug.Locale` resolves it per
  request and stores it in the session; LiveViews re-apply it on mount via
  `VutuvWeb.LiveLocale` (called from `Live.InitAssigns` and `ShellLive.mount`).
  A new LiveView mounted outside the `live_session` must call it too, or its copy
  (and the whole shared chrome) silently falls back to English.
- **Legacy page anatomy:** `.profile-header` h1 → `.breadcrumbs` → `.card-list` >
  `.card` — the header + breadcrumbs are emitted by `<.page_header title=… crumbs=… />`
  (new/edit pages pass only `crumbs`); tables inside cards get edit/delete via the `<.edit_delete_actions>`
  component (canonical `.btns-right` + `.button.button--icon.button--small >
  i.icon.icon--edit|--delete`), placed in the `td` (`td.text-right` for table
  rows); empty collections render `<p class="card__empty">` +
  gettext("Nothing here yet."). Copy this from `email/index` + `group/index`.
- Error pages (`VutuvWeb.ErrorHTML`) render the `.error-page` card (code, message,
  "Back to the start page") and must work with and without the app layout.

### CSS architecture (don't break it)

`app.css` order: `@import "tailwindcss"` → `@import "./components.css" layer(components)`,
**at the top** before `@source`/`@theme` — the `@import … layer()` only works there
(CSS ignores `@import` after other rules). `components.css` lives in the `components`
layer, so it beats Preflight (base) but loses to Tailwind utilities, which lets
hand-written pages use utilities freely. There is **no `legacy.css` anymore** — do not
reintroduce it (a regression test enforces this). Dev serves `/assets/app.css`
undigested, so hard-reload (Cmd+Shift+R) after a rebuild. **Dev does not use
`tailwind --watch`:** the v4 CLI's watch mode rebuilds from a cached copy of
`@import`ed CSS and ignores CSS edits outright (verified on 4.0.0 and 4.3.0), so
`VutuvWeb.TailwindWatcher` (wired as the dev watcher) runs a correct one-shot
build on every CSS/template/JS change instead. Edits to `components.css` reach
the browser within ~2s; if they ever don't, suspect that watcher first.

### Don'ts

- No theme toggle (dark = system).
- Don't reskin legacy pages per-template — edit `components.css`.
- Don't invent new bespoke colours; stay on brand / accent / slate.
- No em-dashes in UI copy (project-wide rule).
