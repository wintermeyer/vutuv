defmodule VutuvWeb.UI do
  @moduledoc """
  Direction A design-system components — reuse these on hand-written pages so the
  visual language stays consistent and DRY. See `.claude/rules/design.md` for the
  full spec and raw-utility recipes. Legacy controller pages are styled centrally
  in `assets/css/components.css`, not here.

  Imported into every HTML view and LiveView via `VutuvWeb` (`html`, `live_view`,
  `live_component`), so all of these are available everywhere with no explicit
  import: `<.card>`, `<.section_title>`, `<.section_header>`, `<.card_menu>`,
  `<.chip>`, `<.button>`, `<.avatar>`, `<.count_badge>`, `<.pager>`.
  """
  use Phoenix.Component
  use Gettext, backend: VutuvWeb.Gettext

  # `<.follow_button>` owns the ~p"/follows…" route shapes, so it needs the
  # verified-route sigil and the `button/2` helper for its icon/text variants.
  use Phoenix.VerifiedRoutes,
    endpoint: VutuvWeb.Endpoint,
    router: VutuvWeb.Router,
    statics: ~w(assets fonts images favicon.ico)

  import PhoenixHTMLHelpers.Link, only: [button: 2]

  alias Vutuv.Tags.UserTag

  @doc """
  Shared input class for hand-written (Track 2) form fields — the Direction A
  input recipe (full width, rounded, slate border, brand focus ring, dark-aware).
  The single source for the post composer, the auth pages and any green-field
  form, so the field look stays consistent. Compose with utilities via a list,
  e.g. `class={[input_class(), "resize-y"]}`.
  """
  def input_class do
    "w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm focus:border-brand-500 focus:outline-none dark:border-slate-700 dark:bg-slate-800 dark:text-slate-100"
  end

  @doc """
  Shared checkbox class for hand-written (Track 2) consent/opt-in boxes —
  the companion to `input_class/0` (brand check on a rounded slate box,
  top-aligned beside its label text, dark-aware). The single source for
  the sign-up form's consent checkboxes.
  """
  def checkbox_class do
    "mt-0.5 h-4 w-4 rounded border-slate-300 text-brand-600 focus:ring-brand-500 dark:border-slate-600 dark:bg-slate-800"
  end

  @doc """
  Wraps every case-insensitive occurrence of `needles` (a string or a list of
  strings) in `text` in a brand-tinted `<mark>` — the search result match
  marker. Returns safe HTML built from escaped parts; `nil`/empty needles
  return the text unchanged (HEEx escapes it as usual).
  """
  def highlight(text, needles) when is_binary(text) do
    needles = needles |> List.wrap() |> Enum.filter(&(is_binary(&1) and &1 != ""))

    if needles == [] do
      text
    else
      downcased = Enum.map(needles, &String.downcase/1)
      pattern = Regex.compile!(Enum.map_join(needles, "|", &Regex.escape/1), "iu")

      marked =
        text
        |> String.split(pattern, include_captures: true)
        |> Enum.map(&mark_part(&1, downcased))

      {:safe, marked}
    end
  end

  defp mark_part(part, downcased) do
    escaped = part |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    if String.downcase(part) in downcased do
      [
        ~s(<mark class="rounded-sm bg-brand-100 text-brand-900 dark:bg-brand-500/30 dark:text-brand-100">),
        escaped,
        "</mark>"
      ]
    else
      escaped
    end
  end

  @doc """
  Dev convenience flag: in dev the Swoosh local adapter drops login / sign-up
  PINs into the mailbox preview at `/sent_emails`. The logged-out auth and PIN
  templates link there when this is on (`config/dev.exs`); it stays off in
  test/prod where that route is absent. Lives here so every `:html` view shares
  it (the login form, both PIN pages).
  """
  def dev_mailbox?, do: Application.get_env(:vutuv, :dev_mailbox, false)

  @doc """
  The "stuck on the PIN page" escape hatches, shared by both PIN-entry screens
  (login and post-registration). "Resend PIN" re-mints and re-mails the one-time
  PIN for the pending email (rate limited); "Use a different email address"
  abandons the pending login so the visitor is no longer pinned to the PIN form
  and can sign in or register as someone else. Both are CSRF-protected POSTs.

  The hint above them is deliberately generic and always shown: it nudges a
  member whose address has stopped working (a bounced, now-undeliverable inbox)
  toward another of their addresses, without ever revealing whether the typed
  address is registered - the PIN screen must stay byte-identical for known and
  unknown addresses (the enumeration guard in `Vutuv.Accounts`).
  """
  def pin_actions(assigns) do
    ~H"""
    <div class="mt-4 text-sm">
      <p class="text-slate-600 dark:text-slate-400">
        {gettext(
          "Not getting the PIN? That email address may no longer be working. If you have added other addresses to your vutuv account, try logging in with one of those instead."
        )}
      </p>
      <div class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-2">
        <.form for={%{}} action={~p"/login/resend"} method="post" id="resend-pin-form">
          <button type="submit" class="font-semibold text-brand-600 hover:text-brand-700">
            {gettext("Resend PIN")}
          </button>
        </.form>
        <span aria-hidden="true" class="text-slate-300 dark:text-slate-600">&middot;</span>
        <.form for={%{}} action={~p"/login/cancel"} method="post" id="cancel-pin-form">
          <button
            type="submit"
            class="font-semibold text-slate-500 hover:text-slate-700 dark:text-slate-400 dark:hover:text-slate-200"
          >
            {gettext("Use a different email address")}
          </button>
        </.form>
      </div>
    </div>
    """
  end

  @doc """
  Logged-out auth / welcome shell (Direction A): a brand-gradient hero panel
  beside a white form card, stacking to a single column on mobile. Shared by the
  sign-up, login and PIN screens so the logged-out entry flow matches the rest
  of the app instead of the old full-bleed photo "imagebox".

  Pass `title` (the hero headline) and optionally `subtitle`; the `:hero` slot
  adds extra hero content (a member count, say) and the default slot is the form
  card body.

  For a hero that needs full control over its heading typography (a founder
  quote with an attribution block, say), pass a `:headline` slot instead — it
  replaces the default `<h1>{@title}` + subtitle. `title` is still required and
  serves as the plain-text fallback.
  """
  attr(:title, :string, required: true)
  attr(:subtitle, :string, default: nil)
  slot(:headline)
  slot(:hero)
  slot(:inner_block, required: true)

  def auth_layout(assigns) do
    ~H"""
    <div class="mx-auto grid max-w-5xl items-stretch gap-6 py-8 md:grid-cols-2 md:gap-8 md:py-12">
      <section class="relative isolate overflow-hidden rounded-2xl bg-gradient-to-br from-brand-700 to-brand-500 p-8 text-white shadow-sm md:p-10 dark:from-brand-800 dark:to-brand-700">
        <%!-- Soft decorative rings — the signature flourish, purely cosmetic. --%>
        <div aria-hidden="true" class="pointer-events-none absolute -right-16 -top-20 -z-10 h-60 w-60 rounded-full bg-white/10"></div>
        <div aria-hidden="true" class="pointer-events-none absolute -bottom-24 -left-12 -z-10 h-52 w-52 rounded-full bg-white/5"></div>
        <div class="flex h-full flex-col justify-center">
          <%= if @headline != [] do %>
            {render_slot(@headline)}
          <% else %>
            <h1 class="text-2xl font-bold leading-tight md:text-3xl">{@title}</h1>
            <p :if={@subtitle} class="mt-4 max-w-sm text-base leading-relaxed text-brand-50">
              {@subtitle}
            </p>
          <% end %>
          {render_slot(@hero)}
        </div>
      </section>
      <.card class="flex flex-col justify-center">
        {render_slot(@inner_block)}
      </.card>
    </div>
    """
  end

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
  Card header row: a `<.section_title>` plus an optional right-aligned `:action`
  slot. Under the unified card UX the owner's **Add** is no longer a header
  button — it is the dashed `<.empty_add>` tile in the card body, shown the same
  way whether the card is empty or already has entries (the whole point: one add
  affordance, never two). So most call sites pass just `title`; the `:action`
  slot remains for the rare non-add header control.
  """
  attr(:title, :string, required: true)
  slot(:action)

  def section_header(assigns) do
    ~H"""
    <div class="mb-4 flex items-center justify-between gap-3">
      <.section_title>{@title}</.section_title>
      <div :if={@action != []} class="flex items-center gap-3">
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
    attr(:id, :string, doc: "optional DOM id for the item link (tests, anchors)")
    attr(:href, :any, doc: "link target (a navigation/CSRF item); omit when using `click`")
    attr(:method, :string)

    attr(:click, :string,
      doc: "phx-click event name — renders a `<button>` (a LiveView action) instead of a link"
    )

    attr(:value, :any, doc: "phx-value-id sent with the `click` event")
    attr(:confirm, :string, doc: "data-confirm prompt for destructive items")
    attr(:danger, :boolean, doc: "style the item red")
  end

  def card_menu(assigns) do
    ~H"""
    <details data-menu class="relative" id={@id}>
      <summary
        title={gettext("Options")}
        class={[
          "flex h-7 w-7 cursor-pointer list-none items-center justify-center rounded-full text-slate-600 dark:text-slate-400",
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
        <%!-- An item with `click` is a LiveView action (a phx-click <button>, no
        reload); otherwise it is a navigation / CSRF <.link>. Both wear the same
        item styling so one menu can mix them. --%>
        <%= for item <- @item do %>
          <button
            :if={item[:click]}
            type="button"
            id={item[:id]}
            phx-click={item[:click]}
            phx-value-id={item[:value]}
            data-confirm={item[:confirm]}
            class={["block w-full text-left", card_menu_item_class(item[:danger])]}
          >
            {render_slot(item)}
          </button>
          <.link
            :if={!item[:click]}
            id={item[:id]}
            href={item[:href]}
            method={item[:method]}
            data-confirm={item[:confirm]}
            class={["block", card_menu_item_class(item[:danger])]}
          >
            {render_slot(item)}
          </.link>
        <% end %>
      </div>
    </details>
    """
  end

  # Shared look for a `<.card_menu>` item, whether it renders as a link or a
  # phx-click button: the calm row, red for a danger item.
  defp card_menu_item_class(danger?) do
    [
      "px-4 py-2 text-sm font-medium",
      if(danger?,
        do: "text-red-600 hover:bg-red-50 dark:text-red-400 dark:hover:bg-red-950/40",
        else: "text-slate-700 hover:bg-slate-50 dark:text-slate-200 dark:hover:bg-slate-800"
      )
    ]
  end

  @doc """
  The owner's **add tile** / onboarding scaffold: a full-width dashed-outline
  tile (plus glyph + a clear label) that links straight to the new-entry form, so
  a non-technical owner sees an obvious place to start filling a section — no
  header button, no hidden ⋯ menu.

  On the **profile** it shows only while the card is **empty** (guard with
  `:if={same_user?(…) and <collection empty>}`); once there are entries the card
  is a clean showcase with a `<.card_footer_link>` "Verwalten ›" instead. The
  exceptions are Beiträge (compose tile stays always) and General Info (empty
  tile graduates to an "Ändern ›" footer). On the legacy **management pages**
  `<.card_section>` renders it above the list, empty or populated (those are the
  editor). Pass the call-to-action label as the inner block (e.g.
  `gettext("Add work experience")`); carries a `data-empty-add` hook for tests.
  """
  attr(:href, :any, required: true)
  attr(:class, :any, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def empty_add(assigns) do
    ~H"""
    <.link
      href={@href}
      data-empty-add
      class={[
        "flex items-center justify-center gap-2 rounded-xl border-2 border-dashed border-slate-200 px-4 py-4 text-sm font-semibold text-slate-500 transition",
        "hover:border-brand-400 hover:bg-brand-50 hover:text-brand-700",
        "dark:border-slate-700 dark:text-slate-400 dark:hover:border-brand-500 dark:hover:bg-brand-900/20 dark:hover:text-brand-300",
        @class
      ]}
      {@rest}
    >
      <svg class="h-5 w-5 shrink-0" fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24" aria-hidden="true">
        <path stroke-linecap="round" stroke-linejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
      </svg>
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc "Tag chip (brand tint). Pass `navigate`/`href` to render it as a link."
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
  The profile **Tags** chip: a tag whose name links to the tag page, the
  visible-endorsement count shown as a calm brand-blue pill right after the name (the
  shell unread counter's shape, recoloured, a vouch count is social proof, not an
  alert), and the named voter roster (`<.voter_popover>`) revealed on hover/focus,
  pure CSS, no JS.

  For the owner and logged-out visitors the pill is **read-only and hidden at 0**. A
  logged-in non-owner gets the **same pill as the endorse toggle**: clicking it
  endorses (POST) or undoes (DELETE); it fills in (brand-600) once endorsed, and a
  zero-count tag shows a "+" so there is something to click. It is a CSRF `<.form>`
  (the no-JS fallback) that the `TagVote` enhancement in `app.js` drives over fetch,
  flipping `data-endorsed` and popping the count when it changes. The count is the
  visible endorsement tally (`compact_count`); the hover roster shows the latest
  endorsers' avatars and names.
  """
  attr(:user, :map, required: true, doc: "the profile owner whose tag this is")

  attr(:user_tag, :map,
    required: true,
    doc: "a UserTag with `endorsements` (and their `:user`) preloaded"
  )

  attr(:viewer, :any,
    default: nil,
    doc: "the current viewer's user struct, or nil when logged out"
  )

  attr(:live?, :boolean,
    default: false,
    doc:
      "on the profile LiveView, toggle the endorsement with a `phx-click` \"endorse\"/\"unendorse\" (the LiveView re-renders the pill + roster, no fetch); otherwise the CSRF form the `TagVote` enhancement drives"
  )

  def tag_vote(assigns) do
    user_tag = assigns.user_tag
    viewer = assigns.viewer
    viewer_id = viewer && viewer.id
    total = Enum.count(user_tag.endorsements)
    can_vote? = viewer_id && viewer_id != assigns.user.id
    endorsed? = viewer_id && Enum.any?(user_tag.endorsements, &(&1.user_id == viewer_id))
    # An actionable viewer's own row is pre-rendered in the popover (hidden until
    # they endorse, then revealed by the JS toggle), so keep them out of the server
    # roster to avoid showing them twice.
    {others, others_total} = roster_for(user_tag, can_vote? && viewer_id, 6)

    assigns =
      assigns
      |> assign(:can_vote?, can_vote?)
      |> assign(:endorsed?, endorsed?)
      |> assign(:total, total)
      |> assign(:count, compact_count(total))
      |> assign(:others, others)
      |> assign(:extra, max(others_total - length(others), 0))
      # Whether the hover roster has anything to show right now. An actionable viewer
      # on a still-unendorsed, no-other-endorser tag still gets the popover in the DOM
      # (so the JS can reveal their row on endorse) but with hover disabled until then.
      |> assign(:roster_active?, others != [] || endorsed?)

    ~H"""
    <div class="group relative inline-flex items-center gap-1.5 rounded-lg bg-brand-50 px-3 py-1.5 text-sm font-medium hover:z-30 focus-within:z-30 dark:bg-brand-900/40">
      <.link
        navigate={~p"/#{@user}/tags/#{@user_tag}"}
        class="text-brand-700 hover:underline dark:text-brand-100"
      >
        {UserTag.truncated_name(@user_tag)}
      </.link>
      <%!-- Actionable viewer (logged-in non-owner): the count pill itself is the
      endorse toggle. It looks just like the read-only pill until you endorse, then
      fills in (brand-600); a zero-count tag shows a "+" so there is something to
      click. In `live?` mode (the profile LiveView) it is a phx-click <button> and
      the LiveView re-renders the pill + roster; otherwise the CSRF <.vote_form>
      (the no-JS fallback the TagVote enhancement in app.js drives over fetch). --%>
      <button
        :if={@can_vote? && @live?}
        type="button"
        phx-click={if(@endorsed?, do: "unendorse", else: "endorse")}
        phx-value-id={@user_tag.id}
        data-tag-vote-count
        data-endorsed={to_string(@endorsed?)}
        aria-pressed={to_string(@endorsed?)}
        title={if(@endorsed?, do: gettext("Remove endorsement"), else: gettext("Endorse"))}
        class={tag_vote_pill_class()}
      >{if(@total > 0, do: @count, else: "+")}</button>
      <.vote_form :if={@can_vote? && !@live?} user={@user} user_tag={@user_tag} endorsed?={@endorsed?}>
        <button
          type="submit"
          data-tag-vote-count
          data-endorsed={to_string(@endorsed?)}
          aria-pressed={to_string(@endorsed?)}
          title={if(@endorsed?, do: gettext("Remove endorsement"), else: gettext("Endorse"))}
          class={tag_vote_pill_class()}
        >{if(@total > 0, do: @count, else: "+")}</button>
      </.vote_form>
      <%!-- Read-only count (owner / logged-out): the tally as a calm brand-tint pill
      inline after the name, no endorsement-word so the Tags section stays about tags
      (tag_wording_test). The actionable viewer above gets the same pill as a button. --%>
      <span
        :if={!@can_vote? and @total > 0}
        class="inline-flex h-[18px] min-w-[18px] items-center justify-center rounded-full bg-brand-100 px-1 text-[11px] font-bold tabular-nums text-brand-700 dark:bg-brand-800 dark:text-brand-100"
      >{@count}</span>
      <.voter_popover
        :if={@total > 0 or @can_vote?}
        user={@user}
        user_tag={@user_tag}
        others={@others}
        extra={@extra}
        self={@can_vote? && @viewer}
        self_endorsed?={@endorsed?}
        active?={@roster_active?}
      />
    </div>
    """
  end

  # The endorse/undo pill's look, shared by the phx-click (live) and CSRF-form
  # renderings so they stay identical: a calm brand-tint pill that fills in
  # (brand-600) once `data-endorsed` flips true.
  defp tag_vote_pill_class do
    [
      "inline-flex h-[18px] min-w-[18px] items-center justify-center rounded-full px-1 text-[11px] font-bold tabular-nums transition-colors",
      "bg-brand-100 text-brand-700 hover:bg-brand-200 dark:bg-brand-800 dark:text-brand-100 dark:hover:bg-brand-700",
      "data-[endorsed=true]:bg-brand-600 data-[endorsed=true]:text-white data-[endorsed=true]:hover:bg-brand-700 dark:data-[endorsed=true]:bg-brand-600"
    ]
  end

  # The endorsers (preloaded users) for a tag's hover roster, newest first by the
  # endorsement id (a UUID v7, so id order is creation order), optionally excluding
  # one user (the actionable viewer, who gets their own pre-rendered row). Returns
  # `{capped_rows, total_rows}` so the caller can compute the "and N more" count.
  # In-memory off the profile's `visible_with_endorser` preload (no per-tag query).
  defp roster_for(user_tag, exclude_id, limit) do
    rows =
      user_tag.endorsements
      |> Enum.reject(&(exclude_id && &1.user_id == exclude_id))
      |> Enum.sort_by(& &1.id, :desc)
      |> Enum.map(& &1.user)

    {Enum.take(rows, limit), length(rows)}
  end

  # An endorser's display name, falling back to their @handle when nameless.
  defp endorser_name(user) do
    [Map.get(user, :first_name), Map.get(user, :last_name)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> case do
      "" -> "@" <> to_string(Map.get(user, :username))
      name -> name
    end
  end

  # The hover roster: a small card of the voters' avatars + names that rises above
  # the chip on hover/focus. Visibility is driven by the chip's `group-hover` /
  # `group-focus-within`; each row is a link to the endorser's profile, so the card
  # accepts pointer events and an invisible `after:` strip bridges the `mb-2` gap so
  # the cursor can travel from chip to card without the hover collapsing. Long names
  # truncate; the roster is capped (endorsers_for) with an "and N more" link to this
  # member's per-tag endorser list (/:slug/tags/:tag/endorsers), which carries the
  # full roster.
  attr(:user, :map, required: true)
  attr(:user_tag, :map, required: true)
  attr(:others, :list, required: true, doc: "endorser rows, the viewer excluded")
  attr(:extra, :integer, default: 0)
  attr(:self, :any, default: nil, doc: "the actionable viewer's user struct, for their own row")
  attr(:self_endorsed?, :any, default: false)
  attr(:active?, :boolean, default: true, doc: "enable hover now (else the JS turns it on)")

  defp voter_popover(assigns) do
    ~H"""
    <div
      data-roster
      class={[
        "absolute bottom-full left-0 z-30 mb-2 hidden w-max max-w-[14rem] rounded-xl bg-white p-2 shadow-lg ring-1 ring-slate-200 after:absolute after:inset-x-0 after:top-full after:h-2 after:content-[''] dark:bg-slate-800 dark:ring-slate-700",
        @active? && "group-hover:block group-focus-within:block"
      ]}
    >
      <ul class="space-y-0.5">
        <%!-- The viewer's own row is always pre-rendered (when they can endorse) but
        hidden until they have, so the JS toggle reveals it without a reload. --%>
        <li :if={@self} data-roster-row data-self-endorser class={[not @self_endorsed? && "hidden"]}>
          <.roster_entry user={@self} />
        </li>
        <li :for={endorser <- @others} data-roster-row>
          <.roster_entry user={endorser} />
        </li>
      </ul>
      <.link
        :if={@extra > 0}
        navigate={~p"/#{@user}/tags/#{@user_tag}/endorsers"}
        class="mt-1 block px-1 text-[11px] text-slate-500 hover:text-brand-600 dark:text-slate-400 dark:hover:text-brand-300"
      >
        {gettext("and %{count} more", count: @extra)}
      </.link>
    </div>
    """
  end

  # One endorser row in the hover roster: avatar + name, a link to their profile.
  attr(:user, :map, required: true)

  defp roster_entry(assigns) do
    ~H"""
    <.link
      navigate={~p"/#{@user}"}
      class="flex items-center gap-2 rounded-lg px-1 py-0.5 hover:bg-slate-100 dark:hover:bg-slate-700/60"
    >
      <.avatar user={@user} size="xs" />
      <span class="min-w-0 truncate text-xs font-medium text-slate-700 dark:text-slate-200">
        {endorser_name(@user)}
      </span>
    </.link>
    """
  end

  # The CSRF endorse/undo form shared by every tag_vote variant: action/method are
  # the no-JS fallback (POST to endorse, DELETE to undo), the data-* attributes feed
  # the `TagVote` fetch enhancement in app.js. The inner button is variant-specific.
  attr(:user, :map, required: true)
  attr(:user_tag, :map, required: true)
  attr(:endorsed?, :any, required: true)
  slot(:inner_block, required: true)

  defp vote_form(assigns) do
    ~H"""
    <.form
      for={%{}}
      action={
        if(@endorsed?,
          do: ~p"/#{@user}/user_tag_endorsements/#{@user_tag}",
          else: ~p"/#{@user}/user_tag_endorsements?#{[id: @user_tag]}"
        )
      }
      method={if(@endorsed?, do: "delete", else: "post")}
      class="contents"
      data-tag-vote="true"
      data-endorse-url={~p"/#{@user}/user_tag_endorsements?#{[id: @user_tag]}"}
      data-unendorse-url={~p"/#{@user}/user_tag_endorsements/#{@user_tag}"}
      data-label-endorse={gettext("Endorse")}
      data-label-unendorse={gettext("Remove endorsement")}
    >
      {render_slot(@inner_block)}
    </.form>
    """
  end

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
      "#{@button_base} bg-slate-100 text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"

  defp button_class("ghost"),
    do:
      "#{@button_base} text-brand-600 hover:bg-brand-50 hover:text-brand-700 dark:hover:bg-slate-800"

  defp button_class("danger"), do: "#{@button_base} bg-red-600 text-white hover:bg-red-700"
  defp button_class(_), do: "#{@button_base} bg-brand-600 text-white hover:bg-brand-700"

  @doc """
  Follow / unfollow control — the single owner of the two `~p"/follows…"`
  route shapes: a CSRF-protected **DELETE** `/follows/<follow_id>` to
  unfollow, or a **POST** `/follows?follow[follower_id][followee_id]` to
  follow, branched on whether `follow_id` is set (`nil` = not following). The
  following-state lookup (`following_by_id` / `user_follows_user?/2`) stays at the
  call site; this component just consumes its result via `follow_id`.

  Pass `follower_id` (the viewer's id) and `followee_id` (the target's id) plus
  the resolved `follow_id`. The owner/visitor/logged-in guards stay at the
  call site too. Three visual variants reproduce the four hand-written call
  sites byte-for-byte:

    * `"icon"` — the `button button--icon` icon-glyph track (`card_list`):
      `i.icon.icon--unfollow` / `i.icon.icon--follow`, rendered through
      `button/2` (a `<button>` with `data-method`).
    * `"text"` — the bespoke text-button track (`user_row`): a `button/2`
      `<button>` reading gettext("Following") / gettext("Follow") with the
      muted/brand link classes.
    * `"button"` — the `<.button>` track (`show`, `teaser`): a secondary
      `<.button>` "Following" / a primary `<.button>` "Follow". `teaser` renders
      only the follow half — pass `follow_id={nil}` (a non-follower can only
      follow) and it emits exactly that one button.
    * `"segment"` — the **clickable outbound cell** of the profile header's
      segmented `<.follow_relationship>` control: a flush, square-cornered,
      `flex-1` `<.link>` whose colour encodes your follow state — green
      "✓ Following" once you follow, the brand call-to-action "Follow" while you
      do not. Sized to sit inside the pill (the wrapper clips the corners). Not
      used on its own.
  """
  attr(:variant, :string, required: true, values: ~w(icon text button segment))
  attr(:follower_id, :any, required: true)
  attr(:followee_id, :any, required: true)
  attr(:follow_id, :any, default: nil, doc: "the follow id, or nil when not following")

  attr(:live?, :boolean,
    default: false,
    doc:
      "in a LiveView (the profile), fire `phx-click` \"follow\"/\"unfollow\" instead of a CSRF link, so the page never reloads. Currently honored by the `segment` variant only."
  )

  def follow_button(%{variant: "icon"} = assigns) do
    ~H"""
    <%= if is_binary(@follow_id) do %>
      <%= button to: ~p"/follows/#{@follow_id}", method: :delete, class: "button button--icon" do %>
        <i class="icon icon--unfollow"></i>
      <% end %>
    <% else %>
      <%= button to: ~p"/follows?#{[follow: %{follower_id: @follower_id, followee_id: @followee_id}]}", method: :post, class: "button button--icon" do %>
        <i class="icon icon--follow"></i>
      <% end %>
    <% end %>
    """
  end

  def follow_button(%{variant: "text"} = assigns) do
    ~H"""
    <%= cond do %>
      <% @live? and is_binary(@follow_id) -> %>
        <button type="button" phx-click="unfollow" phx-value-id={@follow_id} class={text_follow_class(:following)}>
          {gettext("Following")}
        </button>
      <% @live? -> %>
        <button type="button" phx-click="follow" phx-value-followee={@followee_id} class={text_follow_class(:follow)}>
          {gettext("Follow")}
        </button>
      <% is_binary(@follow_id) -> %>
        <%= button to: ~p"/follows/#{@follow_id}", method: :delete, class: text_follow_class(:following) do %>
          {gettext("Following")}
        <% end %>
      <% true -> %>
        <%= button to: ~p"/follows?#{[follow: %{follower_id: @follower_id, followee_id: @followee_id}]}", method: :post, class: text_follow_class(:follow) do %>
          {gettext("Follow")}
        <% end %>
    <% end %>
    """
  end

  def follow_button(%{variant: "button"} = assigns) do
    ~H"""
    <.button :if={is_binary(@follow_id)} variant="secondary" href={~p"/follows/#{@follow_id}"} method="delete">
      {gettext("Following")}
    </.button>
    <.button
      :if={!is_binary(@follow_id)}
      href={~p"/follows?#{[follow: %{follower_id: @follower_id, followee_id: @followee_id}]}"}
      method="post"
    >
      {gettext("Follow")}
    </.button>
    """
  end

  def follow_button(%{variant: "segment"} = assigns) do
    ~H"""
    <%!-- The outbound half fills the left of the <.follow_relationship> pill;
    flex-1 keeps it the same width as the inbound half. Its colour encodes your
    follow state: a green "active" cell (with a check) once you follow, the brand
    call-to-action while you do not. The `title` carries the label for hover and
    screen readers. In `live?` mode it is a phx-click <button> (the profile
    LiveView, no reload); otherwise the CSRF <.link> (the no-JS fallback). Both
    share segment_class/1 so the two render identically. --%>
    <.link
      :if={is_binary(@follow_id) and not @live?}
      href={~p"/follows/#{@follow_id}"}
      method="delete"
      title={gettext("Following")}
      class={segment_class(:following)}
    >
      <span aria-hidden="true">✓</span><span class="whitespace-nowrap">{gettext("Following")}</span>
    </.link>
    <button
      :if={is_binary(@follow_id) and @live?}
      type="button"
      phx-click="unfollow"
      phx-value-id={@follow_id}
      title={gettext("Following")}
      class={segment_class(:following)}
    >
      <span aria-hidden="true">✓</span><span class="whitespace-nowrap">{gettext("Following")}</span>
    </button>
    <.link
      :if={!is_binary(@follow_id) and not @live?}
      href={~p"/follows?#{[follow: %{follower_id: @follower_id, followee_id: @followee_id}]}"}
      method="post"
      title={gettext("Follow")}
      class={segment_class(:follow)}
    >
      <span class="whitespace-nowrap">{gettext("Follow")}</span>
    </.link>
    <button
      :if={!is_binary(@follow_id) and @live?}
      type="button"
      phx-click="follow"
      phx-value-followee={@followee_id}
      title={gettext("Follow")}
      class={segment_class(:follow)}
    >
      <span class="whitespace-nowrap">{gettext("Follow")}</span>
    </button>
    """
  end

  # The two outbound-cell looks of the <.follow_relationship> pill, shared by the
  # CSRF-link and phx-click renderings so they stay pixel-identical: green
  # "active" once you follow, the brand call-to-action while you do not.
  defp segment_class(:following),
    do:
      "flex min-w-0 flex-1 items-center justify-center gap-1.5 overflow-hidden bg-emerald-700 px-2 py-1.5 text-white transition-colors hover:bg-emerald-800 active:bg-emerald-900"

  defp segment_class(:follow),
    do:
      "flex min-w-0 flex-1 items-center justify-center gap-1.5 overflow-hidden bg-brand-600 px-2 py-1.5 text-white transition-colors hover:bg-brand-700 active:bg-brand-800"

  # The `text` follow-button look (the `user_row` rail), shared by the live
  # phx-click and the classic CSRF renderings.
  defp text_follow_class(:following),
    do:
      "ml-auto self-start text-sm font-semibold text-slate-600 dark:text-slate-400 hover:text-slate-600"

  defp text_follow_class(:follow),
    do: "ml-auto self-start text-sm font-semibold text-brand-600 hover:text-brand-700"

  @doc """
  The profile header's **follow relationship** control — one fixed-width
  segmented pill (`w-80`) with two **equal-width halves** (`flex-1`) that is
  **always rendered in full**, so its size never changes between states; the
  relationship status reads at a glance from the text, colour and icon of each
  half. Three segments, always present in this order:

    1. **Outbound toggle** (`a`) — the clickable Follow / Following half, owned by
       `<.follow_button variant="segment">`. Brand call-to-action "Follow" while
       you do not follow; green "✓ Following" once you do.
    2. **Seam** (`span`) — a fixed-width `aria-hidden` glyph that encodes the
       follow direction: `·` none, `→` you follow them, `←` they follow you,
       `⇄` mutual (the seam goes emerald to mark a "vernetzt" mutual follow).
    3. **Inbound status** (`span`) — the read-only inbound half. Always states
       the inbound direction: green "✓ Follows you" when this member follows you,
       muted grey "✗ Doesn't follow you" otherwise.

  A mutual follow lights **both** halves green and the ring emerald, so
  "vernetzt" is unmistakable at a glance.

  `follow_id` is the viewer's follow of this member (`nil` = not following);
  `follows_viewer?` is whether this member follows the viewer back. Keep the
  owner / visitor / logged-in guard on the `:if` at the call site, like
  `<.follow_button>`.
  """
  attr(:follower_id, :any, required: true)
  attr(:followee_id, :any, required: true)
  attr(:follow_id, :any, default: nil, doc: "the viewer's follow id, or nil when not following")
  attr(:follows_viewer?, :boolean, default: false, doc: "does this member follow the viewer back")

  attr(:live?, :boolean,
    default: false,
    doc: "fire the outbound toggle as a `phx-click` (the profile LiveView) instead of a CSRF link"
  )

  def follow_relationship(assigns) do
    follows? = is_binary(assigns.follow_id)
    follows_viewer? = assigns.follows_viewer?
    mutual? = follows? and follows_viewer?

    {seam_glyph, seam_title} =
      cond do
        mutual? -> {"⇄", gettext("You follow each other")}
        follows? -> {"→", gettext("You follow this member")}
        follows_viewer? -> {"←", gettext("This member follows you")}
        true -> {"·", nil}
      end

    assigns =
      assigns
      |> assign(:follows_viewer?, follows_viewer?)
      |> assign(:mutual?, mutual?)
      |> assign(:seam_glyph, seam_glyph)
      |> assign(:seam_title, seam_title)

    ~H"""
    <%!-- Two equal-width halves (flex-1) whose size never changes between follow
    states. Green with a check = an active follow direction, grey with a cross =
    an inactive one; a mutual "vernetzt" follow lights both halves green and the
    ring emerald. The seam glyph (· → ← ⇄) shows the direction. The pill is a
    horizontal row at every width. On a phone it sizes to its labels (`w-auto`,
    each half one line via whitespace-nowrap) with the seam hidden, so it stays
    one short row in the white area beside the avatar (measured ~115px at a 374px
    viewport, well inside the space below the cover) rather than riding up into the
    cover banner. From sm up it is the fixed w-80 pill with the seam. --%>
    <div class={[
      "flex w-52 items-stretch divide-x overflow-hidden rounded-lg text-xs font-semibold ring-1 sm:w-80 sm:text-sm",
      if(@mutual?,
        do: "divide-emerald-300 ring-emerald-300 dark:divide-emerald-700 dark:ring-emerald-700",
        else: "divide-slate-300 ring-slate-200 dark:divide-slate-600 dark:ring-slate-700"
      )
    ]}>
      <.follow_button
        variant="segment"
        follower_id={@follower_id}
        followee_id={@followee_id}
        follow_id={@follow_id}
        live?={@live?}
      />
      <span
        aria-hidden="true"
        title={@seam_title}
        class={[
          "flex w-7 shrink-0 items-center justify-center text-xs",
          if(@mutual?,
            do: "bg-emerald-50 text-emerald-600 dark:bg-emerald-900/40 dark:text-emerald-300",
            else: "bg-slate-50 text-slate-400 dark:bg-slate-800/60 dark:text-slate-500"
          )
        ]}
      >
        {@seam_glyph}
      </span>
      <span
        title={if(@follows_viewer?, do: gettext("This member follows you"), else: gettext("This member doesn't follow you"))}
        class={[
          "flex min-w-0 flex-1 items-center justify-center gap-1.5 overflow-hidden px-2 py-1.5",
          if(@follows_viewer?,
            do: "bg-emerald-700 text-white",
            else: "bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-400"
          )
        ]}
      >
        <%= if @follows_viewer? do %>
          <span aria-hidden="true">✓</span><span class="whitespace-nowrap">{gettext("Follows you")}</span>
        <% else %>
          <%!-- They don't follow you: the full label, no cross. Dropping the ✗ (and
          the segment divider added on the pill) keeps this half from blending into
          the seam glyph beside it. It can truncate on a very narrow phone; the
          title preserves the meaning. --%>
          <span class="whitespace-nowrap">{gettext("Doesn't follow you")}</span>
        <% end %>
      </span>
    </div>
    """
  end

  @doc """
  The **mute / unmute** toggle for a follow you own — silences the followee's
  posts in your feed while keeping the follow (and any mutual "vernetzt"
  status). Owns the `~p"/follows/:id/mute"` PUT route; `muted?` flips the
  state (the icon fills brand-tint while muted) and the title/label. A square
  icon button sized to sit beside the header's follow / message controls. Keep
  the "only when you follow them" guard (`:if={is_binary(@follow_id)}`) at the
  call site, like `<.follow_button>`.
  """
  attr(:follow_id, :any, required: true)
  attr(:muted?, :boolean, default: false)

  def mute_button(assigns) do
    ~H"""
    <%= button to: ~p"/follows/#{@follow_id}/mute", method: :put,
          title: mute_label(@muted?), aria: [label: mute_label(@muted?)],
          class: save_toggle_class(:bookmark, @muted?) do %>
      <.icon_bell_slash />
    <% end %>
    """
  end

  defp mute_label(true), do: gettext("Unmute")
  defp mute_label(false), do: gettext("Mute")

  # Bell-with-slash glyph (heroicons "bell-slash", outline). The muted state is
  # carried by the button's brand-tint background, not a separate solid icon.
  defp icon_bell_slash(assigns) do
    ~H"""
    <svg class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M9.143 17.082a24.248 24.248 0 0 0 3.844.148m-3.844-.148a23.856 23.856 0 0 1-5.455-1.31 8.964 8.964 0 0 0 2.3-5.542m3.155 6.852a3 3 0 0 0 5.667 1.97m1.965-2.277L21 21m-4.225-4.225a23.81 23.81 0 0 0 3.536-1.003 8.967 8.967 0 0 1-2.302-5.39m0 0V9a6 6 0 0 0-9.5-4.875m8.5 4.875c0-1.79-.78-3.4-2.018-4.508M3 3l3.75 3.75M9.5 4.125 12 1.5"
      />
    </svg>
    """
  end

  @doc """
  The profile header's **bookmark this member** toggle — the private, silent
  save (no follow/connection, no notification; see `Vutuv.Social`). Owns the
  `~p"/user_bookmarks…"` route shapes (POST to save, CSRF DELETE to remove,
  branched on `saved?`). A square icon button matching the header controls; the
  solid bookmark marks the saved state. Keep the logged-in / not-owner /
  not-blocked guard on the `:if` at the call site.
  """
  attr(:saved?, :boolean, required: true)
  attr(:target_id, :any, required: true)

  def user_bookmark_button(%{saved?: true} = assigns) do
    ~H"""
    <%= button to: ~p"/user_bookmarks/#{@target_id}", method: :delete,
          title: gettext("Remove bookmark"), aria: [label: gettext("Remove bookmark")],
          class: save_toggle_class(:bookmark, true) do %>
      <.icon_bookmark filled?={true} />
    <% end %>
    """
  end

  def user_bookmark_button(assigns) do
    ~H"""
    <%= button to: ~p"/user_bookmarks?#{[user_bookmark: %{target_user_id: @target_id}]}", method: :post,
          title: gettext("Bookmark"), aria: [label: gettext("Bookmark")],
          class: save_toggle_class(:bookmark, false) do %>
      <.icon_bookmark filled?={false} />
    <% end %>
    """
  end

  @doc """
  The profile header's **like this member** toggle — the counterpart to
  `<.user_bookmark_button>`, owning the `~p"/user_likes…"` route shapes. Same
  private, silent save; the solid heart marks the liked state. Guard at the
  call site like the bookmark toggle.
  """
  attr(:saved?, :boolean, required: true)
  attr(:target_id, :any, required: true)

  def user_like_button(%{saved?: true} = assigns) do
    ~H"""
    <%= button to: ~p"/user_likes/#{@target_id}", method: :delete,
          title: gettext("Unlike"), aria: [label: gettext("Unlike")],
          class: save_toggle_class(:like, true) do %>
      <.icon_heart filled?={true} />
    <% end %>
    """
  end

  def user_like_button(assigns) do
    ~H"""
    <%= button to: ~p"/user_likes?#{[user_like: %{target_user_id: @target_id}]}", method: :post,
          title: gettext("Like"), aria: [label: gettext("Like")],
          class: save_toggle_class(:like, false) do %>
      <.icon_heart filled?={false} />
    <% end %>
    """
  end

  # Square icon-toggle styling for the two profile save controls, sized to sit
  # beside the header's text buttons. The active fill keeps each control's own
  # colour — coral for a like, brand for a bookmark — matching the post action
  # bar; inactive is the calm secondary outline.
  defp save_toggle_class(kind, active?) do
    base =
      "inline-flex h-9 w-9 items-center justify-center rounded-lg ring-1 ring-inset transition"

    state =
      cond do
        active? and kind == :like ->
          "text-accent bg-accent/10 ring-accent/30 hover:bg-accent/20"

        active? ->
          "text-brand-600 bg-brand-50 ring-brand-200 hover:bg-brand-100 dark:text-brand-300 dark:bg-brand-900/30 dark:ring-brand-900/50"

        true ->
          "text-slate-500 ring-slate-200 hover:bg-slate-50 hover:text-slate-700 dark:text-slate-400 dark:ring-slate-700 dark:hover:bg-slate-800"
      end

    [base, state] |> Enum.join(" ")
  end

  @doc """
  User avatar. Pass `user` (a `%Vutuv.Accounts.User{}`, resolved via `Vutuv.Avatar`)
  or a raw `src`. Sizes `xs|sm|md|lg`; `shape` `circle` (default) or `square`.

  Set `presence` to overlay the real-time green "online" dot: the avatar is
  wrapped in a `[data-presence-user-id]` span that the Presence JS hook toggles
  on and off as that member comes and goes (see `assets/js/app.js` and the
  `.presence-dot` rule). The id is read from `user.id`; pass `presence_id` when
  you only have a `src`. The dot stays hidden until the hook confirms the member
  is online, so it never falsely shows on a classic (non-live) page.
  """
  attr(:user, :any, default: nil)
  attr(:src, :string, default: nil)
  attr(:alt, :string, default: "")
  attr(:size, :string, default: "md", values: ~w(xs sm md lg))
  attr(:shape, :string, default: "circle", values: ~w(circle square))
  attr(:class, :string, default: nil)
  attr(:presence, :boolean, default: false)
  attr(:presence_id, :any, default: nil)
  # Lazy by default: list/grid pages (followers, search, the most-followed
  # listing) render ~100 avatars, almost all below the fold, so eager-loading
  # them all fires ~100 image requests on open. An above-the-fold hero (the
  # profile-header avatar) passes loading="eager" so it is not deprioritised.
  attr(:loading, :string, default: "lazy", values: ~w(lazy eager))

  # Neutral placeholder so a call with neither `user` nor `src` still renders a
  # valid <img> instead of a broken one.
  @fallback_avatar "data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%20viewBox='0%200%2024%2024'%3E%3Crect%20width='24'%20height='24'%20fill='%23e2e8f0'/%3E%3Ccircle%20cx='12'%20cy='9'%20r='4'%20fill='%2394a3b8'/%3E%3Cpath%20d='M4%2022c0-4%204-6%208-6s8%202%208%206'%20fill='%2394a3b8'/%3E%3C/svg%3E"

  # Public entry point: wraps the rendered avatar in the presence shell when
  # asked (and an id is resolvable), otherwise renders the bare avatar so the
  # hundreds of dot-less call sites are byte-for-byte unchanged.
  def avatar(assigns) do
    presence_id =
      if assigns.presence do
        raw = assigns.presence_id || (assigns.user && assigns.user.id)
        if raw, do: to_string(raw)
      end

    assigns = assign(assigns, :presence_resolved_id, presence_id)

    ~H"""
    <.presence_wrap id={@presence_resolved_id} size={@size}>
      <.avatar_inner
        user={@user}
        src={@src}
        alt={@alt}
        size={@size}
        shape={@shape}
        class={@class}
        loading={@loading}
      />
    </.presence_wrap>
    """
  end

  @doc """
  Online-presence shell shared by `<.avatar presence>` and the notifications
  kind-glyph: wraps the inner content in a `[data-presence-user-id]` span the
  Presence JS hook toggles the green `.presence-dot` on as that member comes and
  goes. Renders the content **bare** when `id` is nil (no actor, or a source
  without a resolvable id), so non-presence call sites are byte-for-byte
  unchanged. `isolate` + the dot's `z-10` keep the dot above an inner element
  that carries its own z-index (the profile-header avatar over the cover banner,
  which would otherwise hide the dot behind the photo).
  """
  attr(:id, :any, default: nil)
  attr(:size, :string, default: "sm", values: ~w(xs sm md lg))
  slot(:inner_block, required: true)

  def presence_wrap(%{id: nil} = assigns) do
    ~H"{render_slot(@inner_block)}"
  end

  def presence_wrap(assigns) do
    ~H"""
    <span class="relative isolate inline-flex shrink-0" data-presence-user-id={to_string(@id)}>
      {render_slot(@inner_block)}
      <.presence_dot size={@size} hook />
    </span>
    """
  end

  @doc """
  The green "online" dot itself, the one definition of its colour, ring, size
  and position. Each mode owns its own visibility, so a call can never render an
  always-on dot by forgetting a guard:

    * `hook` (inside `<.presence_wrap>`): adds the `.presence-dot` class, hidden
      by default and revealed by the Presence JS hook's generated stylesheet,
      keyed on the wrapper's `data-presence-user-id`.
    * `online` (the shell's own avatar, the messages sidebar): server-driven —
      renders only when `online` is true, from the caller's own online state.

  With neither, it renders nothing (the safe default).
  """
  attr(:size, :string, default: "sm", values: ~w(xs sm md lg))
  attr(:hook, :boolean, default: false)
  attr(:online, :boolean, default: false)

  # Server-driven and offline: render nothing, so no call site can leave an
  # ungated dot stuck on.
  def presence_dot(%{hook: false, online: false} = assigns), do: ~H""

  def presence_dot(assigns) do
    ~H"""
    <span class={[
      @hook && "presence-dot",
      "absolute z-10 rounded-full bg-emerald-500 ring-2 ring-white dark:ring-slate-900",
      presence_dot_pos(@size)
    ]}>
      <span class="sr-only">{gettext("Online")}</span>
    </span>
    """
  end

  # A user without a picture gets an initials tile (matching the shell's
  # top-bar avatar) instead of the anonymous placeholder image — initials
  # tell people apart in lists, a shared grey silhouette does not.
  defp avatar_inner(%{src: nil, user: %{avatar: nil} = user} = assigns) do
    full_name =
      [Map.get(user, :first_name), Map.get(user, :last_name)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")

    assigns = assign(assigns, :initials, name_initials(full_name))

    ~H"""
    <span
      data-avatar
      role={@alt != "" && "img"}
      aria-label={@alt != "" && @alt}
      aria-hidden={@alt == "" && "true"}
      class={[
        avatar_size(@size),
        if(@shape == "square", do: "rounded-2xl", else: "rounded-full"),
        "inline-flex shrink-0 select-none items-center justify-center bg-brand-100 font-semibold text-brand-700 dark:bg-brand-900/40 dark:text-brand-100",
        initials_text_size(@size),
        @class
      ]}
    >{@initials}</span>
    """
  end

  defp avatar_inner(assigns) do
    src =
      assigns.src ||
        (assigns.user && Vutuv.Avatar.display_url(assigns.user, avatar_url_size(assigns.size))) ||
        @fallback_avatar

    assigns = assign(assigns, :resolved_src, src)

    ~H"""
    <img
      data-avatar
      src={@resolved_src}
      alt={@alt}
      loading={@loading}
      decoding="async"
      class={[
        avatar_size(@size),
        if(@shape == "square", do: "rounded-2xl", else: "rounded-full"),
        "object-cover",
        @class
      ]}
    />
    """
  end

  @doc """
  Up to two uppercased initials from a display name (`"Greta Tester"` → `"GT"`),
  `"?"` when there is nothing to abbreviate. Shared by `<.avatar>` and the
  shell's top-bar tile so the two always agree.
  """
  def name_initials(nil), do: "?"

  def name_initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
    |> case do
      "" -> "?"
      initials -> initials
    end
  end

  defp avatar_size("xs"), do: "h-8 w-8"
  defp avatar_size("sm"), do: "h-9 w-9"
  defp avatar_size("lg"), do: "h-24 w-24"
  defp avatar_size(_), do: "h-12 w-12"

  defp initials_text_size("xs"), do: "text-xs"
  defp initials_text_size("sm"), do: "text-xs"
  defp initials_text_size("lg"), do: "text-3xl"
  defp initials_text_size(_), do: "text-base"

  defp avatar_url_size(size) when size in ["xs", "sm"], do: :thumb
  defp avatar_url_size(_), do: :medium

  # Presence-dot position + size, scaled to the avatar. Nudged just outside the
  # lower-right so the white ring reads as a status badge on the corner.
  defp presence_dot_pos("xs"), do: "-bottom-0.5 -right-0.5 h-2.5 w-2.5"
  defp presence_dot_pos("sm"), do: "-bottom-0.5 -right-0.5 h-3 w-3"
  defp presence_dot_pos("lg"), do: "bottom-1 right-1 h-4 w-4"
  defp presence_dot_pos(_), do: "-bottom-0.5 -right-0.5 h-3.5 w-3.5"

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

  @doc """
  The translated name of a calendar month (`1..12`) — the one home of the
  month-name strings the work-experience form options and the profile/ad date
  labels share, instead of a copy of the twelve `gettext` literals per view.
  """
  def month_name(1), do: gettext("January")
  def month_name(2), do: gettext("February")
  def month_name(3), do: gettext("March")
  def month_name(4), do: gettext("April")
  def month_name(5), do: gettext("May")
  def month_name(6), do: gettext("June")
  def month_name(7), do: gettext("July")
  def month_name(8), do: gettext("August")
  def month_name(9), do: gettext("September")
  def month_name(10), do: gettext("October")
  def month_name(11), do: gettext("November")
  def month_name(12), do: gettext("December")

  @doc """
  Exact, thousands-grouped form of a count (`60123` -> `"60,123"`, or
  `"60.123"` under the German locale), for the rare place that wants the full
  number rather than the floored `compact_count/1` — the live member counter on
  the landing page. Grouping separator follows the active Gettext locale.
  """
  def delimited_count(n) when is_integer(n) do
    separator = if Gettext.get_locale(VutuvWeb.Gettext) == "de", do: ".", else: ","

    digits =
      n
      |> abs()
      |> Integer.to_string()
      |> String.reverse()
      |> String.graphemes()
      |> Enum.chunk_every(3)
      |> Enum.map_join(separator, &Enum.join/1)
      |> String.reverse()

    if n < 0, do: "-" <> digits, else: digits
  end

  @doc """
  The show-once credential reveal: a brand-tint box with a `select-all`
  `<code>` line, rendered only while the one-shot flash under `key` holds a
  freshly minted secret (access tokens, client secrets, webhook signing
  secrets). `label` is the "copy it now" sentence; `class` adds margin
  utilities at the call site.
  """
  attr(:flash, :map, required: true)
  attr(:key, :atom, required: true)
  attr(:label, :string, required: true)
  attr(:class, :any, default: nil)

  def secret_once(assigns) do
    assigns = assign(assigns, :secret, Phoenix.Flash.get(assigns.flash, assigns.key))

    ~H"""
    <div
      :if={@secret}
      class={[
        "rounded-lg bg-brand-50 p-4 ring-1 ring-brand-200 dark:bg-brand-900/40 dark:ring-brand-800",
        @class
      ]}
      data-secret-once={@key}
    >
      <p class="text-sm font-semibold text-brand-800 dark:text-brand-100">{@label}</p>
      <code class="mt-2 block select-all break-all rounded bg-white px-3 py-2 text-sm text-slate-800 dark:bg-slate-900 dark:text-slate-100">{@secret}</code>
    </div>
    """
  end

  @doc """
  The single rendering of a viewer-localized timestamp — the `<time>` element
  the `LocalTime` pass rewrites into the viewer's timezone (the LiveView hook on
  live pages, the `time[data-localtime]` DOMContentLoaded sweep on classic ones;
  see `assets/js/app.js`). The server text inside is the no-JS fallback.

  Stored timestamps are UTC, so the `datetime`/`title` is always emitted as
  unambiguous ISO-8601 with a trailing `Z` (a naive datetime is treated as UTC,
  a `DateTime` is rendered with its own offset), the form every browser parses as
  UTC. Hand-rolling the element with a space-separated stamp (no `T`) made some
  browsers read it as *local* time — the bug this component centralizes away.

  Pass `id` when the element lives inside a LiveView so the `LocalTime` hook can
  attach (the hook needs a DOM id); omit it on classic pages, where the
  `data-localtime` sweep handles it. `format` is the `Calendar.strftime/2` form
  of the fallback text (default `"%Y-%m-%d %H:%M"`).
  """
  attr(:at, :any, required: true, doc: "a NaiveDateTime (treated as UTC) or a UTC DateTime")
  attr(:id, :string, default: nil, doc: "DOM id; when set, the LocalTime hook attaches")
  attr(:format, :string, default: "%Y-%m-%d %H:%M")
  attr(:class, :any, default: nil)
  attr(:rest, :global)

  def local_time(assigns) do
    assigns = assign(assigns, :iso, iso_utc(assigns.at))

    ~H"""
    <time
      id={@id}
      phx-hook={@id && "LocalTime"}
      data-localtime
      datetime={@iso}
      title={@iso}
      class={@class}
      {@rest}
    >{Calendar.strftime(@at, @format)}</time>
    """
  end

  defp iso_utc(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso_utc(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt) <> "Z"

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
  The owner-facing moderation freezer notice — the one rendering of "only you
  can see this while a report is handled" (post card, profile header). A
  quiet amber strip with the ⚑ glyph and a "Review" link to the owner's case
  list; `class` sets the per-surface shell (radius, padding, text size).
  Guard visibility (`:if={owner and frozen}`) at the call site.
  """
  attr(:class, :any, default: nil)
  slot(:inner_block, required: true)

  def frozen_banner(assigns) do
    ~H"""
    <p
      data-frozen-banner
      class={[
        "flex flex-wrap items-center gap-1.5 bg-amber-50 font-semibold text-amber-800 ring-1 ring-amber-200 dark:bg-amber-900/30 dark:text-amber-200 dark:ring-amber-900",
        @class
      ]}
    >
      <span aria-hidden="true">⚑</span>
      {render_slot(@inner_block)}
      <.link href={~p"/moderation/cases"} class="underline hover:no-underline">
        {gettext("Review")}
      </.link>
    </p>
    """
  end

  @doc """
  Numbered pagination for offset-paginated browse pages (followers, tags,
  users). Pass the conn params (for the current `?page`) and the total row
  count; windowing comes from `Vutuv.Pages`. Renders nothing when one page
  fits everything. Feed pages use a "Load more" button instead.

  `per_page` overrides the page size (default the site-wide
  `Vutuv.Pages.max_page_items/0`); it must match the `per_page` the query was
  paginated with. `query` is extra query params to carry onto every page link
  (e.g. the active sort), so pagination does not drop the current sort/filter
  — `?page=N` alone would.
  """
  attr(:params, :map, required: true)
  attr(:total, :integer, required: true)
  attr(:per_page, :integer, default: nil)
  attr(:query, :map, default: %{})

  def pager(assigns) do
    per_page = assigns.per_page || Vutuv.Pages.max_page_items()
    total_pages = Vutuv.Pages.total_pages(assigns.total, per_page)
    current = Vutuv.Pages.effective_page(assigns.params, assigns.total, per_page)
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
      <span :if={List.first(@window) > 1} class="px-1 text-slate-600 dark:text-slate-400">…</span>
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
            href={"?" <> URI.encode_query(Map.put(@query, "page", num))}
            class="flex h-9 min-w-9 items-center justify-center rounded-lg px-2 text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-800"
          >
            {num}
          </a>
        <% end %>
      <% end %>
      <span :if={List.last(@window) < @total_pages} class="px-1 text-slate-600 dark:text-slate-400">…</span>
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
    <%!-- New/edit forms pass only crumbs; still give the page one h1 (the last
    crumb is its identity) so screen-reader and keyboard heading navigation work. --%>
    <h1 :if={is_nil(@title) and @crumbs} class="sr-only">{crumbs_title(@crumbs)}</h1>
    <div :if={@crumbs} class="breadcrumbs">
      {VutuvWeb.UserHelpers.gen_breadcrumbs(@crumbs)}
    </div>
    """
  end

  defp crumbs_title(crumbs) do
    crumbs |> List.last() |> crumb_text()
  end

  defp crumb_text(text) when is_binary(text), do: text
  defp crumb_text({text, _href}) when is_binary(text), do: text
  defp crumb_text(other), do: to_string(other)

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
  Legacy (Track 1) `editform__field` wrapper shared by the `editform`
  `form_content` templates: the `<div class="editform__field">` that turns
  `editform__field--error` on when `field` has an error, with the label / input /
  hints / error tags supplied verbatim in the inner block. Replaces the
  hand-rolled `class={"editform__field\#{if error_tag(f, :x), do: " …--error"}"}`
  interpolation across ~50 sites; the `--error` class is driven straight off the
  form's `errors` (same condition `error_tag/2` checks), so the DOM is identical.
  Styled by `components.css`. Use as:

      <.editform_field form={f} field={:value}>
        {label f, :value, gettext("URL")}
        {text_input f, :value}
        {error_tag f, :value}
      </.editform_field>
  """
  attr(:form, :any,
    required: true,
    doc: "the Phoenix.HTML form (the `f` from `<.form :let={f}>`)"
  )

  attr(:field, :atom, required: true, doc: "the field whose error toggles the --error class")
  slot(:inner_block, required: true)

  def editform_field(assigns) do
    ~H"""
    <div class={["editform__field", @form.errors[@field] && "editform__field--error"]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  One settings opt-in row shared by the Privacy and Notifications pages: a
  `<label>` holding a checkbox, a bold heading and a muted helper line. The
  checkbox stays in the `:checkbox` slot at the call site (so the inverted
  `checked_value`/`unchecked_value` consent boxes need no special handling here),
  `label` is the heading, and the inner block is the helper text. Replaces the
  ~6 hand-rolled copies of this `flex items-start gap-3` block. Use as:

      <.setting_toggle label={gettext("New followers")}>
        <:checkbox>{checkbox(f, :email_on_follower?, class: checkbox_class())}</:checkbox>
        {gettext("When someone starts following you.")}
      </.setting_toggle>
  """
  attr(:label, :string, required: true, doc: "the bold heading line")
  slot(:checkbox, required: true, doc: "the checkbox input (kept at the call site)")
  slot(:inner_block, required: true, doc: "the muted helper line under the heading")

  def setting_toggle(assigns) do
    ~H"""
    <label class="flex items-start gap-3 text-sm text-slate-600 dark:text-slate-300">
      {render_slot(@checkbox)}
      <span>
        <span class="block font-medium text-slate-900 dark:text-white">{@label}</span>
        <span class="block font-normal">{render_slot(@inner_block)}</span>
      </span>
    </label>
    """
  end

  @doc """
  A profile section index's body: the owner's drag-and-drop reorder tool
  (`VutuvWeb.SectionReorderLive`, embedded once they have entries) or, for a
  visitor / an empty list, the read-only `card_list` passed as the inner block.
  `section` is the SectionReorderLive key (`"emails"`, `"links"`, …), `slug` the
  owner's username, `editable` whether to show the reorder tool. Folds the
  identical owner-vs-visitor branch the five section index pages repeated.
  """
  attr(:conn, :any, required: true)
  attr(:section, :string, required: true)
  attr(:slug, :string, required: true)
  attr(:editable, :boolean, required: true)
  slot(:inner_block, required: true)

  def reorderable_section(assigns) do
    ~H"""
    <%= if @editable do %>
      {live_render(@conn, VutuvWeb.SectionReorderLive,
        id: "reorder-#{@section}",
        session: %{"section" => @section, "slug" => @slug})}
    <% else %>
      {render_slot(@inner_block)}
    <% end %>
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
  Calm, labeled per-entry actions for the management list/table rows — the
  unified replacement for the loud pencil + red trash-circle icon pair
  (`<.edit_delete_actions>`). Editing/removing an entry now reads the same on
  every management page and matches the calm Direction A surface instead of
  shouting. Renders an "Edit" (brand link) and "Delete" (muted red, CSRF DELETE
  behind a `data-confirm` prompt) text link; omit `edit_to` for delete-only rows
  (tags). Keep the owner guard at the call site. `align` is `:end` (default,
  right-aligned for table-row cells) or `:start` (left-aligned, e.g. under a
  role on the work-experience timeline).
  """
  attr(:edit_to, :string, default: nil)
  attr(:delete_to, :string, default: nil)
  attr(:confirm, :string, default: nil)
  attr(:align, :atom, default: :end)
  attr(:class, :any, default: nil)

  def row_actions(assigns) do
    ~H"""
    <div class={[
      "flex items-center gap-4 text-sm font-semibold",
      @align == :end && "justify-end",
      @class
    ]}>
      <.link :if={@edit_to} href={@edit_to} class="text-brand-600 hover:text-brand-700">
        {gettext("Edit")}
      </.link>
      <.link
        :if={@delete_to}
        href={@delete_to}
        method="delete"
        data-confirm={@confirm || gettext("Are you sure?")}
        class="text-red-600 hover:text-red-700 dark:text-red-400 dark:hover:text-red-300"
      >
        {gettext("Delete")}
      </.link>
    </div>
    """
  end

  @doc """
  The quiet card **footer link** — the "View all (N)" / "Manage" / "View all N
  posts" navigation that sits below a card's entries. A centered, muted text
  link (slate → brand on hover) with a hairline top divider and a trailing
  chevron, so it reads as a calm footer subordinate to the prominent dashed
  `<.empty_add>` tile up top. Defining the look once keeps every card *aus einem
  Guss* instead of pairing the styled add tile with a bare brand link. Pass
  `href` and the label as the inner block; guard rendering with `:if` at the call
  site. `<.manage_footer>` wraps it with the owner/visitor label logic.
  """
  attr(:href, :any, required: true)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def card_footer_link(assigns) do
    ~H"""
    <.link
      href={@href}
      class={[
        "mt-4 flex items-center justify-center gap-1 border-t border-slate-100 pt-3 text-sm font-medium text-slate-500 transition",
        "hover:text-brand-600 dark:border-slate-800 dark:text-slate-400 dark:hover:text-brand-400"
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
      <svg class="h-4 w-4 shrink-0" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24" aria-hidden="true">
        <path stroke-linecap="round" stroke-linejoin="round" d="m8.25 4.5 7.5 7.5-7.5 7.5" />
      </svg>
    </.link>
    """
  end

  @doc """
  The owner's visible path from a profile section card to its dedicated
  management page, folded together with the public "View all" link — so swapping
  the quiet ⋯ menu for a visible `<.add_action>` does not strand the owner with
  no way to edit or remove existing entries. A `<.card_footer_link>` reading
  "View All (N)" once there are more entries than the profile previews
  (`total > preview`, shown to everyone), otherwise a plain "Manage" shown to the
  owner only when at least one entry exists. Renders nothing for a visitor who
  already sees everything.
  """
  attr(:href, :any, required: true)
  attr(:total, :integer, required: true)
  attr(:preview, :integer, required: true)
  attr(:owner, :boolean, default: false)

  def manage_footer(assigns) do
    ~H"""
    <.card_footer_link :if={@total > @preview or (@owner and @total >= 1)} href={@href}>
      <%= if @total > @preview do %>
        {gettext("View All")} ({compact_count(@total)})
      <% else %>
        {gettext("Manage")}
      <% end %>
    </.card_footer_link>
    """
  end

  @doc """
  The owner-only **"View as" preview switcher** shared by the profile
  (`/:slug`) and every profile section page (`/:slug/work_experiences`,
  `/phone_numbers`, …). A segmented control — You / Public — that
  reloads the current page server-side with `?view_as=<mode>`
  (resolved by `VutuvWeb.ViewAs` for sections, `VutuvWeb.UserController` for the
  profile), plus an active-mode banner.

  **Rendered once, from the `app` layout** (`layout/app.html.heex`), pinned at
  the top of `<main>` right below the top navigation bar so it looks and sits
  identically on every owner page. The layout gates it on `@can_preview?` and
  derives `base_path` from `conn.request_path`, so individual templates no
  longer embed it. `preview_as` is the active tier
  (`nil | :public`); `class` adds utilities to the
  outer container (the layout passes a top margin).
  """
  attr(:base_path, :string, required: true)
  attr(:preview_as, :atom, default: nil)
  attr(:public_restricted?, :boolean, default: false)
  attr(:settings_path, :string, default: nil)
  attr(:class, :any, default: nil)

  attr(:live?, :boolean,
    default: false,
    doc:
      "on a LiveView host (the profile) each segment is a `phx-click=\"view_as\"` button (`phx-value-mode`), so switching tiers re-renders with no reload; dead section pages keep the `?view_as=` links"
  )

  def view_as_switcher(assigns) do
    assigns = assign(assigns, :preview?, not is_nil(assigns.preview_as))

    ~H"""
    <div
      id="view-as-switcher"
      class={[
        "rounded-2xl px-3 py-3 ring-1 sm:px-4",
        if(@preview?,
          do: "bg-brand-50 ring-brand-200 dark:bg-brand-900/30 dark:ring-brand-900/50",
          else: "bg-white ring-slate-200 dark:bg-slate-900 dark:ring-slate-800"
        ),
        @class
      ]}
    >
      <%!-- Mobile-first: the "View as" label sits on its own line and the
      segmented control drops below it full-width (w-full forces the flex-wrap),
      so the four segments share the whole row instead of being squeezed beside
      the label. From sm up the control rejoins the label's line (sm:flex-1).
      Each segment truncates so a long localized label (German "Öffentlich")
      ellipsizes on a narrow phone rather than breaking the layout. --%>
      <div class="flex flex-wrap items-center gap-x-3 gap-y-2 text-sm">
        <span class="inline-flex items-center gap-1.5 font-semibold text-slate-700 dark:text-slate-200">
          <svg class="h-4 w-4" fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" d="M2.036 12.322a1.012 1.012 0 0 1 0-.639C3.423 7.51 7.36 4.5 12 4.5c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178Z" />
            <path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z" />
          </svg>
          {gettext("View as")}
        </span>
        <%!-- On the profile (a LiveView, `live?`) each segment is a phx-click
        button so switching tiers re-renders with no reload; the dead section
        pages keep the `?view_as=` links. --%>
        <div class="flex w-full divide-x divide-slate-200 overflow-hidden rounded-lg ring-1 ring-slate-200 sm:w-auto sm:flex-1 dark:divide-slate-700 dark:ring-slate-700">
          <%= for {label, mode} <- [
                {gettext("You"), nil},
                {gettext("Public"), :public}
              ] do %>
            <button
              :if={@live?}
              type="button"
              phx-click="view_as"
              phx-value-mode={mode || :you}
              aria-current={@preview_as == mode && "true"}
              class={view_as_segment_class(@preview_as == mode)}
            >{label}</button>
            <.link
              :if={!@live?}
              href={view_as_href(@base_path, mode)}
              aria-current={@preview_as == mode && "true"}
              class={view_as_segment_class(@preview_as == mode)}
            >{label}</.link>
          <% end %>
        </div>
      </div>
      <p
        :if={@preview?}
        id="view-as-banner"
        class="mt-2 text-sm text-slate-600 dark:text-slate-400"
      >
        <%= case @preview_as do %>
          <% :public -> %>
            {gettext("Preview: how logged-out visitors and search engines see this page.")}
            <%!-- When this member has turned off search-engine indexing or AI
            use, the sentence above no longer fully applies to them, so point to
            the privacy settings that explain and manage it. --%>
            <.link
              :if={@public_restricted? and @settings_path}
              href={@settings_path}
              class="font-semibold text-brand-700 underline underline-offset-2 hover:text-brand-800 dark:text-brand-300 dark:hover:text-brand-200"
            >
              {gettext("More about this.")}
            </.link>
          <% _ -> %>
        <% end %>
      </p>
    </div>
    """
  end

  defp view_as_href(base_path, nil), do: base_path
  defp view_as_href(base_path, mode), do: base_path <> "?view_as=" <> Atom.to_string(mode)

  # One segment's look in `<.view_as_switcher>`, shared by the link (dead pages)
  # and phx-click button (the profile LiveView) renderings.
  defp view_as_segment_class(active?) do
    [
      "min-w-0 flex-1 truncate px-1.5 py-1.5 text-center text-xs font-semibold transition-colors sm:px-3 sm:text-sm",
      if(active?,
        do: "bg-brand-600 text-white",
        else:
          "bg-white text-slate-600 hover:bg-slate-50 dark:bg-slate-900 dark:text-slate-300 dark:hover:bg-slate-800"
      )
    ]
  end

  @doc """
  Legacy (Track 1) card shell shared by the owned-resource index pages and the
  new/edit form wrappers: the `<div class="card-list"><section class="card">…</section></div>`
  boilerplate that used to be copy-pasted into ~30 templates, styled by
  `components.css` (not Tailwind — do not swap in utilities). The `inner_block`
  goes inside the `.card`.

  Pass `add_href` for the owner "Add" affordance (a falsy value hides it, so
  `add_href={same_user?(@user, @current_user) && ~p"/…/new"}` reads naturally)
  and `add_label` to override its label. The add now follows the **unified card
  UX**: when the section has content it is the visible `<.add_action>` in a top
  header row (same look and spot as the profile's `<.section_header>`); when the
  section is empty it becomes the prominent dashed `<.empty_add>` tile instead of
  the old bottom `.card__morelink`. Set `empty` to switch to the empty state
  (a dashed add tile when `add_href` is set, otherwise the `<p class="card__empty">`
  line from `empty_text`). Use it as `<.card_section empty={…} add_href={…}>…</.card_section>`.
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
        <%= cond do %>
          <% @empty and @add_href -> %>
            <.empty_add href={@add_href}>{@add_label || gettext("Add")}</.empty_add>
          <% @empty -> %>
            <p class="card__empty">{@empty_text || gettext("Nothing here yet.")}</p>
          <% true -> %>
            <.empty_add :if={@add_href} href={@add_href} class="mb-4">
              {@add_label || gettext("Add")}
            </.empty_add>
            {render_slot(@inner_block)}
        <% end %>
      </section>
    </div>
    """
  end

  @doc """
  The cursor-pagination "Load more" control shared by the feed-style LiveViews
  (feed, likes/bookmarks, notifications): a centered secondary button that
  emits the `"load-more"` event. Render it with `:if={@more?}`; the inner block
  overrides the default label (the notifications page shows a remaining count).
  """
  attr(:class, :any, default: nil)
  slot(:inner_block)

  def load_more(assigns) do
    ~H"""
    <div class={["text-center", @class]}>
      <.button id="load-more" variant="secondary" phx-click="load-more" phx-disable-with="…">
        {render_slot(@inner_block) || gettext("Load more")}
      </.button>
    </div>
    """
  end

  @doc """
  The outline repost-arrows icon (24×24 stroke), shared by the post card's
  "Reposted by" line and the action bar. Size it via `class`.
  """
  attr(:class, :any, default: "h-5 w-5")

  def icon_repost(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M19.5 12c0-1.232-.046-2.453-.138-3.662a4.006 4.006 0 0 0-3.7-3.7 48.678 48.678 0 0 0-7.324 0 4.006 4.006 0 0 0-3.7 3.7c-.017.22-.032.441-.046.662M19.5 12l3-3m-3 3-3-3m-12 3c0 1.232.046 2.453.138 3.662a4.006 4.006 0 0 0 3.7 3.7 48.656 48.656 0 0 0 7.324 0 4.006 4.006 0 0 0 3.7-3.7c.017-.22.032-.441.046-.662M4.5 12l3 3m-3-3-3 3"
      />
    </svg>
    """
  end

  @doc """
  The outline reply arrow icon (24×24 stroke), shared by the post card's
  "Replying to" banner and the action bar. Size it via `class`.
  """
  attr(:class, :any, default: "h-5 w-5")

  def icon_reply(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" d="M9 15 3 9m0 0 6-6M3 9h12a6 6 0 0 1 0 12h-3" />
    </svg>
    """
  end

  @doc """
  The outline bookmark icon (24×24 stroke), shared by the shell's saved-pages
  entry and the action bar; `filled?` switches to the solid fill. Size it via
  `class`.
  """
  attr(:class, :any, default: "h-5 w-5")
  attr(:filled?, :boolean, default: false)

  def icon_bookmark(assigns) do
    ~H"""
    <svg
      class={@class}
      fill={if(@filled?, do: "currentColor", else: "none")}
      stroke="currentColor"
      stroke-width="1.8"
      viewBox="0 0 24 24"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M17.593 3.322c.1.128.157.288.157.456v16.444a.75.75 0 0 1-1.218.585L12 17.21l-4.532 3.597A.75.75 0 0 1 6.25 20.222V3.778c0-.168.057-.328.157-.456A2.25 2.25 0 0 1 8.25 2.5h7.5a2.25 2.25 0 0 1 1.843.822Z"
      />
    </svg>
    """
  end

  @doc """
  The outline heart icon (24×24 stroke), shared by the post action bar's Like
  toggle and the profile's "like this member" toggle; `filled?` switches to the
  solid fill. Size it via `class`.
  """
  attr(:class, :any, default: "h-5 w-5")
  attr(:filled?, :boolean, default: false)

  def icon_heart(assigns) do
    ~H"""
    <svg
      class={@class}
      fill={if(@filled?, do: "currentColor", else: "none")}
      stroke="currentColor"
      stroke-width="1.8"
      viewBox="0 0 24 24"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M21 8.25c0-2.485-2.099-4.5-4.688-4.5-1.935 0-3.597 1.126-4.312 2.733-.715-1.607-2.377-2.733-4.313-2.733C5.1 3.75 3 5.765 3 8.25c0 7.22 9 12 9 12s9-4.78 9-12Z"
      />
    </svg>
    """
  end

  @doc """
  The settings sub-navigation shared by the profile editor and the settings
  pages: a row of underline tabs (Profile / Privacy / Notifications / Apps /
  Account) so the once-single edit form now reads as a small set of focused
  pages you can move between. `active` is the current tab key
  (`:profile | :privacy | :notifications | :apps | :account`).
  """
  attr(:user, Vutuv.Accounts.User, required: true)
  attr(:active, :atom, required: true)
  attr(:class, :string, default: nil)

  def settings_nav(assigns) do
    tabs = [
      {gettext("Profile"), ~p"/#{assigns.user}/edit", :profile},
      {gettext("Privacy"), ~p"/#{assigns.user}/settings/privacy", :privacy},
      {gettext("Notifications"), ~p"/#{assigns.user}/settings/notifications", :notifications},
      {gettext("Apps"), ~p"/#{assigns.user}/settings/apps", :apps},
      {gettext("Account"), ~p"/#{assigns.user}/settings", :account}
    ]

    assigns = assign(assigns, :tabs, tabs)

    ~H"""
    <nav class={[
      "-mb-px flex flex-wrap gap-x-6 gap-y-1 border-b border-slate-200 text-sm font-semibold dark:border-slate-800",
      @class
    ]}>
      <.link
        :for={{label, href, key} <- @tabs}
        navigate={href}
        aria-current={@active == key && "page"}
        class={[
          "border-b-2 px-1 py-3",
          if(@active == key,
            do: "border-brand-600 text-brand-700 dark:border-brand-400 dark:text-brand-300",
            else:
              "border-transparent text-slate-600 hover:border-slate-300 hover:text-slate-900 dark:text-slate-400 dark:hover:text-slate-200"
          )
        ]}
      >
        {label}
      </.link>
    </nav>
    """
  end
end
