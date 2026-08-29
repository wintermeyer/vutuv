defmodule VutuvWeb.PostComponents do
  @moduledoc """
  The post card, shared by every place a post renders: the permalink page
  (`mode={:full}`), the feed and the profile section (`mode={:preview}`).

  Preview mode ships the whole body and clamps it via CSS (`.post-clamp`,
  or the height-based `.post-clamp--media` once the body carries inline
  images); a "Read more" button expands it in place, so a long post reads
  the same on the feed and the profile. **Both modes render
  inline-referenced attachments in place** — `![](…)` with an own-upload
  URL, optional `#left`/`#right`/`#center` alignment — and the
  unreferenced rest as a gallery (full) / image tile row (preview) below
  the body.

  Not imported globally — `import VutuvWeb.PostComponents` where needed.
  """

  use Phoenix.Component
  use Gettext, backend: VutuvWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: VutuvWeb.Endpoint,
    router: VutuvWeb.Router,
    statics: ~w(assets fonts images favicon.ico)

  import VutuvWeb.UI
  import VutuvWeb.UserHelpers, only: [full_name: 1]

  alias Phoenix.LiveView.JS
  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.Handle
  alias Vutuv.Fediverse.Note
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Fediverse.RemoteImage
  alias Vutuv.Fediverse.RemotePost
  alias Vutuv.Isbn
  alias Vutuv.Languages
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Organizations.Organization
  alias Vutuv.Posts
  alias Vutuv.Posts.GalleryLayout
  alias Vutuv.Posts.PhotoLicense
  alias Vutuv.Posts.PostImage
  alias Vutuv.Posts.PostRemoteReply
  alias Vutuv.Posts.PostReview
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.Profiles.VerifiedLinks
  alias Vutuv.RemoteMedia
  alias Vutuv.ReviewCover
  alias Vutuv.Tags
  alias Vutuv.Translations.Translation
  alias VutuvWeb.FediverseComponents
  alias VutuvWeb.Live.PostTranslations
  alias VutuvWeb.Markdown
  alias VutuvWeb.PostLive.RemoteActionsComponent
  alias VutuvWeb.UserHelpers

  # The idle tint every action control wears while it is off, paired with each
  # control's own active colour. One place, because the optimistic flip toggles
  # the pair as a unit and both action bars share it.
  @idle_action_class "text-slate-600 dark:text-slate-400"

  # How many reposter faces the "Reposted by" avatar stack shows before the
  # rest collapse into a `+N` chip. Five keeps the strip to one tidy line even
  # on a phone (5 × 20px avatars, overlapped, plus the chip and the sentence).
  #
  # It comes from `Vutuv.Posts` because the roster query loads exactly this many
  # rows (`reposter_roster_cap/0`): a larger number here would ask the stack to
  # draw faces the query never fetched.
  @repost_stack_cap Posts.reposter_roster_cap()

  # A single preview image counts as "roughly square" when its aspect ratio sits
  # inside a 5:4 / 4:5 envelope (a factor of 1.25 either side of 1:1). Such an
  # image, shown full-width, overruns the max-h cap and object-cover crops it to a
  # middle band — so it is laid out beside the text (2/3 text, 1/3 image) instead,
  # where it shows in full. The window is deliberately narrow: a clearly landscape
  # photo (4:3 = 1.33 and wider) reads fine full-width and stays there. The 736×678
  # GitHub code card that prompted this (~1.09) sits comfortably inside it.
  @square_ratio_min 0.8
  @square_ratio_max 1.25

  attr(:post, :any, required: true, doc: "preloaded %Vutuv.Posts.Post{}")
  attr(:viewer, :any, default: nil)

  attr(:acting_as, :any,
    default: nil,
    doc:
      "the page the viewer is currently speaking as (issue #1336) — the action bar then likes and reshares in ITS name, the same way the composer already posts in it"
  )

  attr(:viewer_follow, :any,
    default: nil,
    doc:
      "the viewer's follow edge to this post's author, %{id:, muted?:} | nil — drives the menu's mute toggle"
  )

  attr(:mode, :atom, default: :preview, values: [:preview, :full])

  attr(:pinned?, :boolean,
    default: false,
    doc:
      "render the \"Pinned post\" banner (issue #1110). Set where the pin is in " <>
        "effect — the author's profile — so a feed card never claims a pin it is " <>
        "not the showcase for. A `:full` card (the permalink, the post's own " <>
        "page) resolves it itself and needs no flag"
  )

  attr(:show_reply_banner, :boolean,
    default: true,
    doc:
      "render the \"Replying to @handle\" banner for a reply. Set false where the " <>
        "caller already shows the parent post inline (the profile thread), so the " <>
        "banner would just duplicate it"
  )

  attr(:surface, :atom,
    default: :card,
    values: [:card, :flat],
    doc: ":card stands alone; :flat embeds inside an existing card (profile Posts section)"
  )

  attr(:quotable, :boolean,
    default: true,
    doc:
      "let a text selection inside this card's body ride along to the reply page " <>
        "as a quote (issue #1114). Set false where the Reply link leads back to " <>
        "the page the reader is already composing on"
  )

  attr(:conn_or_socket, :any,
    required: true,
    doc: "@conn (dead pages) or @socket (LiveViews) — anchors the embedded live action bar"
  )

  attr(:reposted_by, :any,
    default: nil,
    doc: "%User{} who carried this post into the timeline — renders the \"Reposted by\" line"
  )

  attr(:reposters, :any,
    default: nil,
    doc:
      "every reposter behind the entry (newest first, from Posts.feed_page/2) — " <>
        "renders the banner's avatar stack. nil falls back to [reposted_by], so " <>
        "single-reposter callers (profile, dead lists) need not pass it"
  )

  attr(:reposters_total, :integer,
    default: nil,
    doc:
      "how many resharers the roster stands for when it was capped " <>
        "(`Vutuv.Posts.reposter_roster_cap/0`); nil means the list is the total"
  )

  attr(:entry_id, :string,
    default: nil,
    doc:
      ~s|timeline entry id ("post-<id>" / "repost-<id>") — keeps embedded LiveView ids | <>
        "unique when the same post renders more than once on a page"
  )

  attr(:class, :string, default: nil)

  attr(:engagement, :any,
    default: nil,
    doc:
      "preloaded engagement map (Posts.post_engagement_map/2) handed to the card's " <>
        "action bar so it skips its own mount query; nil = the bar loads it itself"
  )

  attr(:likers, :any,
    default: nil,
    doc:
      "the \"Liked by\" row (issue #1233) as " <>
        "%{users: [%User{}], total: integer, private?: boolean}, or nil for no row. " <>
        "Only the post permalink passes it — a per-card avatar row down a long " <>
        "feed is a query-batching problem and visual noise, so the feed keeps " <>
        "the plain count"
  )

  attr(:translations, :map,
    default: nil,
    doc:
      "the host's translation map (issue #1462), key {:post, id} → :pending | " <>
        "%Vutuv.Translations.Translation{} (= shown). The card looks itself up. " <>
        "nil (every non-LiveView surface) means this viewer gets no translation " <>
        "controls; hosts pass a map exactly when VutuvWeb.Live.PostTranslations." <>
        "available?/1 says yes"
  )

  def post_card(assigns) do
    # The reader's post-display preferences (per-breakpoint line clamp +
    # hyphenation), fed onto the body as CSS custom properties below. There is
    # deliberately no per-surface override: the one surface that ever capped
    # these was the logged-out landing page's wall of posts, and it is gone.
    prefs = User.post_prefs(assigns.viewer)

    # A logged-in viewer (vs anonymous / a "View as public" preview, both nil),
    # bound once and reused for the acting-viewer id and the reporter test.
    viewer = assigns.viewer
    user? = match?(%User{}, viewer)
    author? = Posts.author?(assigns.post, viewer)

    # AI-moderation limbo (Vutuv.Moderation.ImageScans): the author and admins
    # see a pending image themselves (plus the progress panel below); every
    # other viewer gets the photo's mosaic, or a neutral tile where there is
    # none (`held_photo/1`). The post struct is patched once, so every branch
    # below (gallery, inline refs, square layout) works on the filtered set.
    {shown_images, held_images} = split_gallery(assigns.post, viewer)

    post = %{assigns.post | images: shown_images}

    # The whole body is always shipped to the DOM. In :preview the CSS clamp
    # does the visual cut and the in-place expand button reveals the rest, so
    # "Read more" expands in place instead of navigating to the permalink —
    # feed and profile alike. Inline images render in place in BOTH modes
    # from the viewer-visible set (shown_images), so an unreleased picture
    # simply stays absent for strangers while the author sees it; a preview
    # body carrying inline images switches to the height-based media clamp
    # (`inline_media?` below — a line clamp cannot hold pictures or floats).
    # The card's translation state (issue #1462): a shown translation swaps
    # the body source before the Markdown render, so the translated text goes
    # through the exact pipeline + sanitizer the original does — no new XSS
    # surface. The gallery/inline split below stays keyed on the ORIGINAL
    # body: the translator leaves image references untouched.
    translation = card_translation(assigns, {:post, post.id}, post.body, post.language)

    # A link in the body that points at a webpage this author has PROVED is
    # theirs wears the verified mark (issue #1246). The links ride in on the
    # already-preloaded author (`Vutuv.Posts.post_preloads/0`), so a feed of
    # fifty cards costs one batched query, not fifty — and a surface that
    # renders a card without that preload simply marks nothing.
    body_html =
      Markdown.render_post(translation.body_source, post.images,
        verified_links: VerifiedLinks.of(post.user)
      )

    # Attachments the body references inline render in place; the rest form
    # the gallery (full mode) / the image tile row (preview).
    inline_media? = Enum.any?(post.images, &PostImage.referenced_in?(&1, post.body))
    gallery = Enum.reject(post.images, &PostImage.referenced_in?(&1, post.body))

    # Every per-card DOM id derives from the timeline entry when there is one:
    # the same post can render twice on a page (original + repost), and the ids
    # must stay unique. Bound once here so the id assigns below don't each repeat
    # the `entry_id || post.id` fallback.
    entry_key = assigns.entry_id || post.id

    assigns =
      assigns
      |> assign(:post, post)
      |> assign(:held_images, held_images)
      |> assign(:limbo_pill?, author_photo_check?(post, author?))
      # How far the AI scan has got, for the author's progress line. Counted
      # from the post's own (unfiltered) image list, so "2 of 5" means the
      # photos the author attached, not the subset this viewer can see.
      |> assign(:check_progress, Posts.image_check_progress(assigns.post))
      |> assign(:body_html, body_html)
      # The inline CSS custom properties (`--post-clamp-*` / `--post-hyphens-*`)
      # that carry the reader's preference onto the post body; nil for a default
      # / logged-out reader, so their DOM stays clean and the CSS fallbacks apply.
      |> assign(:body_style, post_body_style(prefs))
      # The card's translation view-state (the same map the remote cards
      # keep): the line's three states + the body's `lang` attribute (screen
      # readers, hyphenation — worth having independent of any translation).
      # A shown translation is in the reader's own language.
      |> assign(:translation, translation)
      |> assign(:restricted?, Posts.restricted?(post))
      |> assign(:permalink, Posts.path(post))
      |> assign(:gallery, gallery)
      |> assign(:inline_media?, inline_media?)
      # The authored inline placement owns the media layout: the float-a-square-
      # image and screenshot-beside-the-text automatics stay off when the body
      # embeds pictures itself.
      |> assign(
        :square_layout?,
        not inline_media? and square_layout?(post, gallery, assigns.mode)
      )
      |> assign_link_screenshot(post, assigns.mode)
      # The book/film review sidecar; nil for ordinary posts (and for nested
      # renderings whose preload chain didn't carry it).
      |> assign(:review, review_of(post))
      # Whether that card becomes a right-hand aside beside the prose on a
      # wide screen (see the body block below). A review post with no body has
      # nothing to sit beside, so its card stays the full width of the card.
      |> assign(:review_aside?, review_of(post) != nil and post.body != "")
      |> assign(:actions_id, "post-actions-#{entry_key}")
      # The action bar's acting viewer id (nil = logged-out / public preview).
      # On a LiveView host the inline component is handed this directly; on a
      # dead page the standalone bar reads it from the session instead. nil (not
      # the `false` an `&&` would yield) — Posts.post_engagement/2 only accepts a
      # user id or nil.
      |> assign(:viewer_id, if(user?, do: viewer.id))
      # The identity the bar ACTS as. `/feed` stays the member's own reading
      # surface while they are switched into a page — what changes is whose
      # name the act goes out under, exactly the split the composer makes.
      |> assign(:acting_as_id, assigns.acting_as && assigns.acting_as.id)
      |> assign(:menu_id, "post-menu-#{entry_key}")
      # Keyed on the timeline entry like every other id here, so the same post
      # rendered twice on a page keeps unique pin controls.
      |> assign(:pin_item_id, "pin-post-#{entry_key}")
      |> assign(:unpin_item_id, "unpin-post-#{entry_key}")
      |> assign(:report_menu_id, "post-report-#{entry_key}")
      |> assign(:time_id, "post-time-#{entry_key}")
      |> assign(:body_id, "post-body-#{entry_key}")
      |> assign(:author?, author?)
      # Who this post is BY, resolved once (issue #1334): a member, or the
      # organization it was published in the name of. Everything the header
      # needs is derived here rather than branched at each of the half-dozen
      # places that name the author, and `Posts.author/1` is the single decision
      # about which of the two author columns speaks.
      |> assign(:author, Posts.author(post))
      |> assign(:organization_author?, Posts.organization_post?(post))
      |> assign(:author_path, Posts.author_path(post))
      |> assign(:author_name, UserHelpers.author_name(post))
      # Whether this post is the one its author pinned to their profile (issue
      # #1110) — read off the already-preloaded author, so it costs no query.
      # Drives the menu's Pin / Unpin label and its "replaces the other one"
      # prompt; the visible banner is the caller's `pinned?` (see the attr).
      # An organization has no profile to pin to, so it is simply false there.
      |> assign(:pinned_to_profile?, Posts.pinned?(post.user, post))
      |> assign(:pin_replaces_other?, pin_replaces_other?(post))
      # The visible marker: wherever the caller says the pin is in effect, plus
      # the permalink — the post's own page, where "this one is pinned to their
      # profile" is simply a fact about it. A feed preview stays unmarked.
      |> assign(
        :show_pin_banner?,
        assigns.pinned? or (assigns.mode == :full and Posts.pinned?(post.user, post))
      )
      # The no-query half of Posts.editable?/1 — the feed renders many cards.
      |> assign(:editable?, Posts.edit_window_open?(post))
      |> assign(:reporter?, user? and not Posts.author?(post, viewer))
      |> assign(:frozen?, post.frozen_at != nil)
      |> assign(:reply_banner, reply_banner(post, assigns.show_reply_banner, assigns[:viewer]))
      |> assign(:reposters, repost_roster(assigns))
      |> assign(:edited?, Posts.edited?(post))

    ~H"""
    <.card :if={@surface == :card} class={@class}>
      {render_post_card_inner(assigns)}
    </.card>
    <div :if={@surface == :flat} class={@class}>
      {render_post_card_inner(assigns)}
    </div>
    """
  end

  @doc """
  The shared shell for a threaded post list: a `divide-y` column of
  `<.post_thread_entry>` rows, optionally wrapped in a `<.card>`. Every post
  surface (feed, saved, profile Posts section, archive, permalink thread) renders
  through this, so the container — card wrap, divider colour, row rhythm — lives
  in one place.

  The rows themselves stay at the call site (a `:for` over a static list, or a
  LiveView `phx-update="stream"` comprehension whose children must be bound where
  the stream assign lives), each a `<div class={post_row_class()}>` around one
  `<.post_thread_entry>`. Stream attrs (`id`, `phx-update`, `data-filter-list`) flow
  through the global `rest` onto the divider column.
  """
  attr(:card, :boolean,
    default: true,
    doc: "wrap in a <.card>; false when the list is already inside one (the profile section)"
  )

  attr(:class, :string, default: nil, doc: "outer-wrapper utilities, e.g. mt-3 spacing")
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def post_list(assigns) do
    ~H"""
    <.card :if={@card} class={@class}>
      <div class="divide-y divide-slate-100 dark:divide-slate-800" {@rest}>
        {render_slot(@inner_block)}
      </div>
    </.card>
    <div
      :if={!@card}
      class={["divide-y divide-slate-100 dark:divide-slate-800", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  The row-wrapper class every `<.post_list>` child uses: vertical rhythm plus
  flush first/last so the top and bottom rows sit against the card padding.
  """
  def post_row_class, do: "py-4 first:pt-0 last:pb-0"

  @doc """
  The value/label pairs for the post-type filter tabs (issue #945): All,
  Own posts, Reposts, Replies. The four together partition the timeline (an
  entry is exactly one of them), the reason a segmented tab bar fits. Values
  match `Vutuv.Posts.normalize_post_filter/1`.
  """
  def post_filter_options do
    [
      {"all", gettext("All")},
      {"posts", gettext("Own posts")},
      {"reposts", gettext("Reposts")},
      {"replies", gettext("Replies")}
    ]
  end

  @doc """
  The value/label pairs for the **feed's** source tabs: All, vutuv, Fediverse.
  Like the post-type tabs above they partition what they filter — an entry
  either carries a vutuv post or a cached one from another network
  (`Vutuv.Posts.remote_feed_entry?/1`), never both — so the same segmented
  control fits. Values match `Vutuv.Posts.normalize_feed_filter/1`.

  "vutuv" and "Fediverse" are proper names and stay untranslated; only "All"
  is a word.
  """
  def feed_filter_options do
    [
      {"all", gettext("All")},
      {"vutuv", "vutuv"},
      {"fediverse", "Fediverse"}
    ]
  end

  @doc """
  The feed's per-tab empty-state line, so an empty tab says which half of the
  feed is missing rather than repeating the generic invitation to follow
  people.
  """
  def feed_filter_empty_text("vutuv"),
    do: gettext("Nothing from vutuv yet. Follow people here to fill this tab.")

  def feed_filter_empty_text("fediverse"),
    do: gettext("Nothing from the fediverse yet. Follow accounts out there to fill this tab.")

  def feed_filter_empty_text(_all), do: nil

  @doc """
  The per-tab empty-state line, keyed by the active filter so an empty tab
  says what is missing ("No reposts yet.") instead of a bare "Nothing here".
  """
  def post_filter_empty_text("posts"), do: gettext("No posts yet.")
  def post_filter_empty_text("reposts"), do: gettext("No reposts yet.")
  def post_filter_empty_text("replies"), do: gettext("No replies yet.")
  def post_filter_empty_text(_all), do: gettext("Nothing here yet.")

  @doc """
  The `/:slug/posts` archive path for `user` scoped to a filter — the plain
  archive for `"all"`, otherwise a `?type=` variant. Shared by the profile's
  "View all" footer link and the archive's own tabs.
  """
  def post_archive_path(user, "all"), do: ~p"/#{user}/posts"
  def post_archive_path(user, type), do: ~p"/#{user}/posts?#{[type: type]}"

  @doc """
  The "add one" affordance a feed-rail card wears instead of a permanently open
  text field.

  Three cards each carried a field — follow a tag, hide a word, hide a tag — and
  together they spent about 150px of a 330px column on controls a reader touches
  a handful of times a year (Stefan, 2026-08-28). The field is behind a native
  `<details>` now, so it costs one small line at rest, opens with no JavaScript
  and no server state, and keeps its own open/closed state for assistive tech.

  The summary is a `+` pill at the end of a row of chips, where it costs no
  height at all. **Open, the whole thing takes the full width of that row**
  (`open:w-full`), so the flex-wrap puts it on a line of its own and the field is
  as wide as the card: as a normally-sized flex item it grew *beside* the chips
  instead, stretching them to its height and leaving the input a third of the
  card wide (reported 2026-08-28). One class rather than a reveal flag on the
  server, so nothing here can be lost to a patch.

  Open, the glyph turns into a ✕ and **moves inside the field**, at its right
  edge: a toggle on a line of its own costs a whole row for one 28px button, and
  a ✕ sitting in the box it closes is where a reader looks for it anyway.

  It gets there by leaving the flow (`group-open:absolute` against an
  `open:relative` details), not by flex. Flex is the obvious answer and does not
  work: `display: flex` on a `<details>` makes the summary one flex item and
  wraps everything after it in the browser's own `::details-content` box, so a
  `flex-1` on the form grows nothing — measured at 182px in a 297px row. Taking
  the summary out of the flow sidesteps that box entirely and needs no
  browser-specific selector.

  `data-keep-open` is what stops the next unrelated patch (a count ticking) from
  folding it shut under the reader's cursor.
  """
  attr(:label, :string, required: true)
  attr(:placeholder, :string, required: true)
  attr(:submit, :string, required: true)
  attr(:change, :string, default: nil)
  attr(:name, :string, default: "pattern")
  attr(:value, :string, default: "")
  attr(:maxlength, :any, default: nil)
  attr(:target, :any, default: nil)
  attr(:class, :string, default: nil)

  def rail_add_field(assigns) do
    ~H"""
    <details data-keep-open class={["group open:relative open:w-full", @class]}>
      <summary
        title={@label}
        class="inline-flex h-7 w-7 cursor-pointer list-none items-center justify-center rounded-lg bg-slate-100 text-sm font-semibold text-slate-500 hover:bg-slate-200 hover:text-slate-800 group-open:absolute group-open:right-[3px] group-open:top-1/2 group-open:-translate-y-1/2 group-open:bg-transparent group-open:hover:bg-slate-200 [&::-webkit-details-marker]:hidden dark:bg-slate-800 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100 dark:group-open:bg-transparent dark:group-open:hover:bg-slate-700"
      >
        <%!-- The glyph turns into a ✕ once the field is open. A "+" that stays
        a "+" offers nothing to press to get rid of the field again, and the
        reader is left with a box they cannot put away (reported 2026-08-28) —
        the toggle worked all along, it just did not say so.

        Each span owns `display` exactly once and conditionally (issue #880's
        rule): the plus hides while open, the cross hides while closed. Neither
        carries a base `hidden` beside a variant that has to out-cascade it. --%>
        <span aria-hidden="true" class="group-open:hidden">+</span>
        <span aria-hidden="true" class="group-[:not([open])]:hidden">×</span>
        <span class="sr-only">{@label}</span>
      </summary>

      <form phx-submit={@submit} phx-change={@change} phx-target={@target}>
        <%!-- `pr-10` keeps the typed text clear of the ✕ sitting over the
        field's right edge. --%>
        <input
          type="text"
          name={@name}
          value={@value}
          maxlength={@maxlength}
          phx-debounce={@change && "300"}
          placeholder={@placeholder}
          class="w-full rounded-lg border border-slate-200 bg-slate-50 py-1.5 pl-3 pr-10 text-sm text-slate-900 placeholder:text-slate-400 focus:border-brand-500 focus:outline-none dark:border-slate-700 dark:bg-slate-950 dark:text-slate-100"
        />
      </form>
    </details>
    """
  end

  @doc """
  The filter tab bar (issue #945): the one control for "which of these am I
  looking at", worn by the profile's Beiträge card, the `/:slug/posts` archive
  and the feed's source tabs. Two modes, one look:

    * pass `event` for a LiveView host (the profile, the feed) — each tab is a
      `phx-click` button firing `event` with `phx-value-type`, so it toggles
      with no reload;
    * pass `base_path` for a dead page (the `/:slug/posts` archive) — each tab
      is a plain link to `base_path` (+ `?type=`), a full navigation.

  `active` is the current filter string; the matching tab reads as selected.
  `options` swaps the tab set — the feed passes `feed_filter_options/0` for
  its All / vutuv / Fediverse source tabs, which are the same control asking
  a different question.

  **It carries no filled track, and that is load-bearing.** The bar used to be
  a segmented control on a `bg-slate-100` track, which reads correctly inside
  a white card (the profile, the archive) and is *literally invisible* on the
  feed — the page canvas is `slate-100`, the identical colour, so the feed's
  tabs were a lone white pill floating on nothing while the profile's sat in a
  proper trough. One filled colour cannot contrast with both of this app's
  backgrounds, so the state rides the **active tab** instead: a brand-tinted
  pill, which reads on white and on the canvas alike. That is the same
  vocabulary the shell's top-bar nav uses for the page you are on, so "which
  of these am I on" looks the same everywhere in the app.

  `unseen` dots the tabs holding something the reader has not seen (issue
  #1503) — the coral dot the notifications list wears, and a dot rather than a
  count because the host knows *that* something landed there, not how much.
  The active tab never carries one whatever is passed: you are looking at it.

  """
  attr(:active, :string, required: true)
  attr(:event, :string, default: nil, doc: "phx-click event name → button mode")
  attr(:base_path, :string, default: nil, doc: "archive base path → link mode")

  attr(:options, :list,
    default: nil,
    doc: "value/label pairs; defaults to post_filter_options/0"
  )

  attr(:unseen, :list, default: [], doc: "tab values carrying an unseen dot")

  attr(:class, :any,
    default: "mb-4",
    doc:
      "the row's own spacing. The default is the gap every stacked caller wants; the tag page shares one flex row with its filter toggle and passes none, since a bottom margin there would knock the two controls out of line with each other."
  )

  attr(:rest, :global, doc: "container attrs, e.g. an id for tests")

  def post_filter_tabs(assigns) do
    assigns = assign(assigns, :options, assigns.options || post_filter_options())

    ~H"""
    <%!-- No `role="tablist"`: these are toggle buttons carrying `aria-pressed`
    (and links carrying `aria-current` on the archive). A real tablist owes the
    reader a roving tabindex and arrow-key traversal, the same call the emoji
    picker's group tabs made. --%>
    <%!-- Wrapping is decided here rather than in CSS: `flex-wrap` is a Tailwind
    utility and components.css is a cascade layer, so a rule there would lose to
    it. --%>
    <div class={["filter-tabs flex flex-wrap gap-1 text-sm", @class]} {@rest}>
      <%= for {value, label} <- @options do %>
        <button
          :if={@event}
          type="button"
          phx-click={@event}
          phx-value-type={value}
          data-filter-tab={value}
          aria-pressed={to_string(@active == value)}
          class={post_filter_tab_class(@active == value)}
        >
          <.tab_label label={label} /><.unseen_dot show={value != @active and value in @unseen} />
        </button>
        <.link
          :if={!@event}
          href={post_filter_link(@base_path, value)}
          data-filter-tab={value}
          aria-current={@active == value && "page"}
          class={post_filter_tab_class(@active == value)}
        >
          <.tab_label label={label} /><.unseen_dot show={value != @active and value in @unseen} />
        </.link>
      <% end %>
    </div>
    """
  end

  # The label in a span of its own, so the dot beside it has a sibling to sit
  # against rather than a bare text node.
  attr(:label, :string, required: true)

  defp tab_label(assigns) do
    ~H"""
    <span class="filter-tab__label">{@label}</span>
    """
  end

  # The quote itself: a button, not a tab — it switches to the source it names
  # and takes the window with it, which is also what the tab beside it does.
  # The hook owns the clock (assets/js/app.js): the seconds run in the browser,
  # where the window is actually visible, and it hides itself before telling
  # the server, so a dead socket cannot leave the quote standing.
  # The unseen marker: the same 8px coral dot an unread notification row wears,
  # here riding beside the label rather than over it — a tab is text, so there
  # is no icon to sit on the corner of. Screen readers get the word; the dot
  # carries no number, so there is nothing else to say.
  attr(:show, :boolean, required: true)

  defp unseen_dot(assigns) do
    ~H"""
    <span
      :if={@show}
      data-post-filter-unseen
      class="ml-1.5 inline-block h-2 w-2 rounded-full bg-accent align-middle"
    >
      <span class="sr-only">{gettext("New")}</span>
    </span>
    """
  end

  # The active tab is a brand-tinted pill, the rest quiet muted text that tints
  # on hover — the shell's top-bar nav treatment for the page you are on,
  # reused so the app has one look for "which of these am I on".
  #
  # **Every colour here is picked to read against BOTH page backgrounds**, the
  # thing the old filled track could not do. Checked side by side in a browser
  # over white and over the canvas, because the near-misses are invisible on
  # screen and obvious only when you put them next to each other:
  #
  #   * `brand-50` (#eff6ff) vs the `slate-100` canvas (#f1f5f9) differ by ~6
  #     in one channel — the shell gets away with it because its header is
  #     white, here it vanishes. `brand-100` reads on both, and it is already
  #     the tint the profile's tag count pill wears.
  #   * the hover is `slate-200`, not `slate-100`, for the same reason.
  #   * `brand-600` + white text reads everywhere but is the primary-CTA
  #     weight, far too loud for a row of filters.
  #
  # `py-2.5` keeps the tap target at 40px, the mobile-first floor.
  defp post_filter_tab_class(true),
    do:
      "whitespace-nowrap rounded-lg bg-brand-100 px-3 py-2.5 font-semibold text-brand-700 dark:bg-brand-900/40 dark:text-brand-100"

  defp post_filter_tab_class(false),
    do:
      "whitespace-nowrap rounded-lg px-3 py-2.5 font-medium text-slate-600 hover:bg-slate-200 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-800 dark:hover:text-slate-100"

  # Link-mode href: the plain base path for "all", a `?type=` variant otherwise.
  defp post_filter_link(base_path, "all"), do: base_path
  defp post_filter_link(base_path, type), do: base_path <> "?type=" <> type

  @doc """
  The collapsed composer trigger: the viewer's avatar beside an input-shaped
  pill, the composer pattern every network trains. Card-weight on purpose —
  its dashed `<.empty_add>` predecessor was an outline rather than a surface
  and read as a void next to solid cards.

  Two homes, one look: the top of **/feed** (no `href`, so it renders a
  `<button>` whose reveal is wired via `rest` — `id="open-composer"` +
  `phx-click="open-composer"`, the id both the "n" shortcut and the `#compose`
  arrival hash click) and the **profile's Beiträge card**
  (`href={~p"/feed#compose"}`, a link that opens the feed with the composer
  revealed and focused). The default `surface={:card}` carries its own white
  card shell for standing alone on the canvas; pass `surface={:flat}` when it
  sits inside an existing card. Carries `data-composer-trigger` for tests.
  """
  attr(:viewer, :any, required: true, doc: "the viewer; their avatar anchors the row")
  attr(:href, :any, default: nil)
  attr(:surface, :atom, default: :card, values: [:card, :flat])

  attr(:avatar_size, :string,
    default: nil,
    doc:
      "overrides the surface's avatar default (:card md / :flat sm) — the feed " <>
        "wraps a :flat trigger in its own card beside the camera button and keeps " <>
        "the big page-anchor avatar"
  )

  attr(:class, :any, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def composer_trigger(assigns) do
    assigns =
      assign(assigns, :shell_class, [
        "group flex w-full items-center gap-3 text-left",
        assigns.surface == :card &&
          "rounded-2xl bg-white p-4 shadow-sm ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800",
        assigns.class
      ])

    ~H"""
    <%= if @href do %>
      <.link href={@href} data-composer-trigger class={@shell_class} {@rest}>
        <.composer_trigger_body viewer={@viewer} surface={@surface} avatar_size={@avatar_size}>
          {render_slot(@inner_block)}
        </.composer_trigger_body>
      </.link>
    <% else %>
      <button type="button" data-composer-trigger class={@shell_class} {@rest}>
        <.composer_trigger_body viewer={@viewer} surface={@surface} avatar_size={@avatar_size}>
          {render_slot(@inner_block)}
        </.composer_trigger_body>
      </button>
    <% end %>
    """
  end

  attr(:viewer, :any, required: true)
  attr(:surface, :atom, required: true)
  attr(:avatar_size, :string, required: true)
  slot(:inner_block, required: true)

  # Standalone (:card, the feed) carries the big `md` avatar as the page's
  # anchor. Flat (:flat) sits among post rows, so it follows their grammar:
  # the same `sm` avatar the post headers use (a bigger one towers over the
  # list and shifts the pill off the post text column) and a py-2 pill, which
  # at text-sm comes out exactly avatar-high (36px).
  defp composer_trigger_body(assigns) do
    ~H"""
    <.avatar user={@viewer} size={@avatar_size || if(@surface == :card, do: "md", else: "sm")} />
    <span class={[
      "flex-1 rounded-full bg-slate-100 px-4 text-sm text-slate-500 group-hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-400 dark:group-hover:bg-slate-700",
      if(@surface == :card, do: "py-2.5", else: "py-2")
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  One row of a threaded post timeline — the single rendering of a
  post-with-context shared by the feed, the profile Posts section, the saved
  lists, the post archive and the permalink reply thread, so a reply reads the
  same everywhere instead of the feed's old flat "Replying to @handle" banner.

  When the entry is a reply, the posts it answers render **above** it as a
  **nested conversation** (`thread_chain/1`): each is a full `<.post_card>`
  (keeping its own like / repost / bookmark bar), oldest-first, and every reply is
  **indented one step further right** under the post it answers — a left-rail,
  left-padded block per level — so the reply depth reads at a glance the way a
  threaded comment tree does, however many posts or authors the thread spans. The
  leaf reply drops its own "Replying to @handle" banner (the posts above show the
  relationship). A top-level post, a reply whose parent is gone (the card's
  degraded banner covers it), or `nest_parent={false}` on the permalink (where the
  parent *is* the page) renders as a standalone card.

  `ancestors` is the ordered, oldest-first list of the posts this one answers
  (from `Posts.collapse_threads/1`); the feed and profile pass the whole visible
  chain, so a multi-post thread renders once. When it is not given, the component
  falls back to the single preloaded `reply_ref` parent (one level), which is all
  the archive / permalink / saved lists need. `ancestor_engagement` is a
  `%{post_id => engagement}` map for those ancestor cards' action bars (the feed
  batches it; nil entries make a bar self-load, the profile path).

  Forwards the same post/viewer/engagement/reposted_by/entry_id/conn_or_socket
  the `<.post_card>` takes to the leaf card; `surface` picks the leaf shell
  (`:flat` inside a divide-y list, `:card` standalone). A list entry is always a
  `:preview` card — the one `:full` rendering (the permalink's own post) uses
  `<.post_card>` directly.
  """
  attr(:post, :any, required: true, doc: "preloaded %Vutuv.Posts.Post{}")
  attr(:viewer, :any, default: nil)

  attr(:acting_as, :any, default: nil)
  attr(:viewer_follow, :any, default: nil)
  attr(:engagement, :any, default: nil)

  attr(:ancestors, :any,
    default: nil,
    doc:
      "oldest-first list of the posts this one answers; nil falls back to the " <>
        "single preloaded reply_ref parent (one level)"
  )

  attr(:ancestor_engagement, :map,
    default: %{},
    doc: "%{post_id => engagement} for the ancestor cards' action bars; missing = self-load"
  )

  attr(:remote_replies, :map,
    default: %{},
    doc:
      "`%{post_id => [%Note{}]}` for the thread's posts (`Vutuv.Posts.attach_thread_notes/2`), " <>
        "woven in among the vutuv replies; empty on a surface that does not host their events"
  )

  attr(:note_marks, :any,
    default: nil,
    doc: "the viewer's like/repost/bookmark flags per note (`Vutuv.Fediverse.mark_lookup/2`)"
  )

  attr(:remote_parents, :map,
    default: %{},
    doc:
      "`%{post_id => decorated cached post}` (`Vutuv.Posts.attach_remote_parents/3`) for the " <>
        "posts here that answer one out there (issue #1165) — drawn above them as a card"
  )

  attr(:reposted_by, :any, default: nil)
  attr(:reposters, :any, default: nil)
  attr(:reposters_total, :integer, default: nil)
  attr(:entry_id, :string, default: nil)
  attr(:surface, :atom, default: :flat, values: [:card, :flat])
  attr(:conn_or_socket, :any, required: true)

  attr(:nest_parent, :boolean,
    default: true,
    doc:
      "nest a reply's parent post inline. false where the parent is already on " <>
        "the page (the permalink thread), so the row is just the flat card"
  )

  attr(:translations, :map, default: nil)

  def post_thread_entry(assigns) do
    # An explicit [] means "collapsed, no ancestors" (a root/standalone) and must
    # not fall back; only a missing (nil) list falls back to the one-level parent.
    ancestors = assigns.ancestors || one_level_ancestors(assigns.post, assigns.nest_parent)
    assigns = assign(assigns, :ancestors, ancestors)
    assigns = assign(assigns, :roots, thread_entry_roots(assigns))

    ~H"""
    <%!-- Content from another network makes a lone post a conversation too —
    replies under it (issue #1069), or the post it answers out there (issue
    #1165) — so the flat card is only for a post that has none of the three. --%>
    <%= if @ancestors == [] and @remote_replies == %{} and @remote_parents == %{} do %>
      <.post_card
        post={@post}
        viewer={@viewer}
        acting_as={@acting_as}
        viewer_follow={@viewer_follow}
        engagement={@engagement}
        reposted_by={@reposted_by}
        reposters={@reposters}
        reposters_total={@reposters_total}
        entry_id={@entry_id}
        surface={@surface}
        conn_or_socket={@conn_or_socket}
        translations={@translations}
        show_reply_banner={@nest_parent}
      />
    <% else %>
      <%!-- The reply and the posts it answers, as one conversation: each is a
      full post card (its own like / repost / bookmark bar), and every reply is
      nested one step further right under the post it answers — a left-rail,
      left-padded block per level — so the reply depth reads at a glance the way
      a threaded comment tree does. --%>
      <.thread_chain
        nodes={@roots}
        viewer={@viewer}
        surface={@surface}
        conn_or_socket={@conn_or_socket}
        translations={@translations}
      />
    <% end %>
    """
  end

  # The card specs for a threaded conversation, nested into the reply tree they
  # really form (`Vutuv.Posts.thread_forest/1`): the ancestors (engagement from
  # the batched map) plus the leaf (which keeps its own follow edge, repost line
  # and engagement). Each ancestor's `entry_id` is derived from the leaf entry so
  # DOM ids stay unique even when the same post is nested under more than one
  # reply on the page.
  defp thread_entry_roots(assigns) do
    leaf_key = assigns.entry_id || assigns.post.id

    ancestors =
      Enum.map(assigns.ancestors, fn post ->
        %{
          post: post,
          engagement: assigns.ancestor_engagement[post.id],
          viewer_follow: nil,
          reposted_by: nil,
          reposters: nil,
          reposters_total: nil,
          entry_id: "#{leaf_key}-parent-#{post.id}"
        }
      end)

    leaf = %{
      post: assigns.post,
      engagement: assigns.engagement,
      viewer_follow: assigns.viewer_follow,
      reposted_by: assigns.reposted_by,
      reposters: assigns.reposters,
      reposters_total: assigns.reposters_total,
      entry_id: assigns.entry_id
    }

    (ancestors ++ [leaf])
    |> Posts.thread_forest()
    |> banner_on_roots()
    |> weave_remote_replies(
      assigns.remote_replies,
      assigns.viewer,
      assigns.note_marks || fn _note -> nil end
    )
    |> nest_remote_parents(assigns.remote_parents)
  end

  # Puts the cached post an answer answers above it, as the root of that branch
  # (issue #1165). Only a root can have one: a post that answers something out
  # there has no parent *here*, so `thread_forest/1` never nests it under
  # anything. The answer keeps its own card and loses its "Replying to" line,
  # the card above now being what that line was pointing at.
  defp nest_remote_parents(roots, parents) when parents == %{}, do: roots

  defp nest_remote_parents(roots, parents) do
    Enum.map(roots, fn root ->
      case parents[root.post.id] do
        nil -> root
        parent -> Map.put(parent, :children, [%{root | show_reply_banner: false}])
      end
    end)
  end

  # A card that hangs under the post it answers needs no "Replying to @handle"
  # banner — the nesting already says it. A forest root is the other case: its
  # parent is off the page (or gone), so it keeps the banner naming the author
  # it answers.
  defp banner_on_roots(roots), do: Enum.map(roots, &Map.put(&1, :show_reply_banner, true))

  # How many levels of a thread visibly indent before the indentation is capped.
  # Beyond this, deeper replies keep stacking in the same column (the connector
  # becomes a straight vertical drop) instead of marching further right. A card's
  # min-content is ~267px and a 360px phone (the narrow floor we support) leaves
  # ~60px of slack past that, so 2 levels of `pl-7` (28px) stay comfortably
  # on-screen; letting the indent grow unbounded scrolled a deep thread sideways.
  @thread_indent_cap 2

  # Renders a conversation **tree** with a **connector line that runs from each
  # avatar into the avatars of the replies it got** (like a mail/forum thread):
  # a vertical drop from a card's avatar down past everything that answers it,
  # then — in the block holding each answer — an elbow curving from that column
  # into the answer's avatar. Every reply is indented one `pl-7` step under the
  # post it answers until the indent is capped (see above), past which replies
  # stay in the same column and the connector is a straight vertical drop.
  # The avatar centre is `1.125rem` in from the card's left (the `sm` avatar),
  # which is why the connectors sit at `left-[1.125rem]`.
  #
  # `nodes` are siblings — the conversation's roots at depth 0, one post's
  # answers below that (`Vutuv.Posts.thread_forest/1`), each carrying its own
  # `:children`. A post answered **twice** therefore branches: the spine keeps
  # running past the first answer's whole subtree down into the next one, and
  # only the last sibling closes it with the rounded elbow. Before this the
  # chain was flat and chronological, so a reply written after a busy branch
  # point rendered under a post it had nothing to do with (issue #1027).
  attr(:nodes, :list, required: true)
  attr(:depth, :integer, default: 0)
  attr(:viewer, :any, default: nil)
  attr(:surface, :atom, required: true)
  attr(:conn_or_socket, :any, required: true)

  attr(:connected?, :boolean,
    default: false,
    doc: "these nodes answer a card above them, so each draws its connector back into its column"
  )

  attr(:acting_as, :any, default: nil)
  attr(:translations, :map, default: nil)

  defp thread_chain(assigns) do
    # `@thread_indent_cap` is a module attribute, not an assign, so resolve the
    # "still indenting?" flag here — inside ~H, `@name` would mean assigns.name.
    assigns =
      assigns
      |> assign(:indent?, assigns.depth <= @thread_indent_cap)
      |> assign(:nodes, mark_last(assigns.nodes))

    ~H"""
    <div
      :for={{node, first?, last?} <- @nodes}
      class={[
        @connected? && "relative pt-3",
        @connected? && @indent? && "pl-7",
        # Separate roots: unrelated conversations (a thread whose links a
        # deleted post broke), so they get air instead of a connector.
        !@connected? && !first? && "mt-4"
      ]}
    >
      <%!-- The connector into this answer's avatar, drawn in the column of the
      card it answers (left-[1.125rem] of this block, which the pl-7 does not
      move). The last answer closes the spine with an elbow curving into its
      avatar's left edge at the avatar's vertical centre (pt-3 + 1.125rem =
      1.875rem down); an earlier answer instead lets the spine run the full
      height of its subtree — down to the next sibling — and taps into its own
      avatar with a short horizontal tick at that same 1.875rem. Capped depth
      puts the answer in the same column as its parent, so the connector is a
      straight vertical drop through the padding. --%>
      <span
        :if={@connected? && @indent? && last?}
        class="absolute left-[1.125rem] top-0 h-[1.875rem] w-2.5 rounded-bl-xl border-b-2 border-l-2 border-slate-200 dark:border-slate-700"
        aria-hidden="true"
      >
      </span>
      <span
        :if={@connected? && @indent? && !last?}
        class="absolute left-[1.125rem] top-0 h-full w-0.5 rounded-full bg-slate-200 dark:bg-slate-700"
        aria-hidden="true"
      >
      </span>
      <span
        :if={@connected? && @indent? && !last?}
        class="absolute left-[1.125rem] top-[1.875rem] h-0.5 w-2.5 rounded-full bg-slate-200 dark:bg-slate-700"
        aria-hidden="true"
      >
      </span>
      <span
        :if={@connected? && !@indent?}
        class="absolute left-[1.125rem] top-0 h-3 w-0.5 rounded-full bg-slate-200 dark:bg-slate-700"
        aria-hidden="true"
      >
      </span>
      <div
        id={Map.get(node, :focus?) && "thread-focus"}
        data-thread-scroll={Map.get(node, :scroll?)}
        class={[
          "relative",
          # The permalink's highlighted subject (issue #1006): the tint is an
          # absolutely positioned ::before so the chain's connector geometry
          # (avatar columns, elbows) is untouched; z-0 opens a stacking
          # context so -z-10 stays in front of the page card's background.
          Map.get(node, :focus?) &&
            "z-0 scroll-mt-24 before:absolute before:-inset-x-3 before:-inset-y-2 before:-z-10 before:rounded-xl before:bg-brand-50/70 before:ring-1 before:ring-brand-200 before:content-[''] dark:before:bg-brand-900/20 dark:before:ring-brand-800"
        ]}
      >
        <%!-- Drops from this avatar's bottom (top-9) to the card's bottom; the
        elbow below continues it into the answer's avatar. Only when this card
        was answered. Height is an explicit `calc(100% - top)`, not `top-9` +
        `bottom-0`: an empty absolutely-positioned box sized only by
        `top`/`bottom` (auto height) collapses to zero on iOS/mobile Safari, so
        the whole thread line vanished on phones while the explicit-height
        elbows survived. An explicit height renders identically everywhere. --%>
        <span
          :if={node.children != []}
          class="absolute left-[1.125rem] top-9 h-[calc(100%-2.25rem)] w-0.5 rounded-full bg-slate-200 dark:bg-slate-700"
          aria-hidden="true"
        >
        </span>
        <%!-- A node is a vutuv post, a reply from another network (issue #1069)
        sitting among them as an ordinary sibling in time order, or the cached
        post an answer answers (issue #1165) at the head of its branch. The last
        two wear their own skin. --%>
        <%= cond do %>
          <% Map.has_key?(node, :remote_post) -> %>
            <%!-- The head of the branch, so no reshare line and no ⋯ owner
            item: what it says is "this is what is being answered". Its own
            menu's three events are the cached card's everywhere
            (`VutuvWeb.Live.RemotePostActions`), which every host of this
            chain already handles. --%>
            <.remote_post_card
              live?
              remote_post={node.remote_post}
              images={node[:images] || []}
              marks={node[:marks]}
              following?={node[:following?] == true}
              viewer={@viewer}
              translations={@translations}
            />
          <% Map.has_key?(node, :note) -> %>
            <%!-- `acts?` unconditionally: the conversation is only ever rendered
            by a LiveView that handles the heart's events — and on a throwaway
            dead render the buttons are as live as every other `phx-click` on
            the page, which is to say the moment the socket connects. --%>
            <.remote_reply_card
              note={node.note}
              owner?={node.owner?}
              viewer={@viewer}
              marks={node.marks}
              translations={@translations}
              live?
            />
          <% true -> %>
            <.post_card
              post={node.post}
              viewer={@viewer}
              acting_as={@acting_as}
              viewer_follow={node.viewer_follow}
              engagement={node.engagement}
              reposted_by={node.reposted_by}
              reposters={node.reposters}
              reposters_total={node[:reposters_total]}
              entry_id={node.entry_id}
              surface={@surface}
              conn_or_socket={@conn_or_socket}
              mode={Map.get(node, :mode, :preview)}
              likers={Map.get(node, :likers)}
              translations={@translations}
              show_reply_banner={reply_banner?(node, @connected?, @indent?)}
            />
        <% end %>
      </div>
      <.thread_chain
        :if={node.children != []}
        nodes={node.children}
        depth={@depth + 1}
        connected?={true}
        viewer={@viewer}
        surface={@surface}
        conn_or_socket={@conn_or_socket}
        translations={@translations}
      />
    </div>
    """
  end

  @doc """
  One reply written on **another network**, rendered as a sibling of the vutuv
  replies in the same conversation (issues #1069 and #1071).

  Same rhythm as a `<.post_card>` — avatar column, name, time, body, in the same
  36px geometry so the thread's connector lines still land on the avatar centres
  — and deliberately different material, because a reader has to be able to tell
  the two worlds apart at a glance and without colour:

    * an initials tile in **slate**, not the brand tint members get, carrying the
      globe badge that issue #1068 established for "another network". No picture
      is ever fetched or hosted: vutuv does not host a third party's image.
    * the author's name as plain text (there is no vutuv profile to link to)
      beside their `@handle@host`, which links out to the account.
    * **two acts, not four.** Answering it and liking it both mean something
      across the network boundary and both are here (issue #1270); resharing and
      bookmarking somebody else's reply on somebody else's server do not, so
      those are absent rather than dead.

  Those two acts sit in a **row of their own under the body**, not in the
  provenance footer, which is what they were built into first and what made the
  card read as having no actions at all: a `text-xs` word between the server
  name and "View the original" is a caption, and nobody presses a caption. They
  are the size the rest of the app's controls are (issue #1270 was reported as
  "I have no way to like or answer this").

  What is **stored** is plain text (`Vutuv.RemoteHtml` reduced the remote HTML
  at the inbox, and that does not change). What is **shown** is that text run
  through `VutuvWeb.Markdown.render_remote/1` — see `remote_body/1` — so the
  links a post from those networks mostly consists of are clickable instead of
  sitting there as raw strings. It is the foreign-namespace renderer on purpose:
  a bare `@mention` stays plain text rather than minting a link into the local
  profile of whoever shares that handle. The "view the original" link carries
  the reader on when they want the real thing.

  A note its author put behind a content warning renders the warning as a closed
  lid and reveals the text on a click, which is the one thing that author asked
  for.

  Rendered inside `VutuvWeb.PostLive.Thread` (the conversation) and, without its
  acts, as the read-only target of the answering page — so the takedown controls
  and the heart are plain `phx-click` events on the host LiveView.
  """
  attr(:note, :map, required: true, doc: "a Vutuv.Fediverse.Note")

  attr(:owner?, :boolean,
    default: false,
    doc: "whether the viewer is the member whose post this answers (they may remove it)"
  )

  attr(:viewer, :any, default: nil, doc: "the logged-in member, or nil")

  attr(:live?, :boolean,
    default: false,
    doc:
      "whether this surface is a LiveView that can host the action bar. False on a dead controller page, where a LiveComponent cannot render at all, and on the answering page, where the card is the read-only thing being answered."
  )

  attr(:marks, :any,
    default: nil,
    doc:
      "the viewer's like/repost/bookmark flags for this subject when the host batched them (`Vutuv.Fediverse.liked_ids/2` and friends); nil lets the bar load its own."
  )

  attr(:reposted_by, :any,
    default: nil,
    doc:
      "the member whose reshare put this reply in the reader's feed (issue #1275), or nil in a conversation, where it stands under the post it answers"
  )

  attr(:translations, :map,
    default: nil,
    doc: "the host's translation map (issue #1462), key {:note, id} — see <.post_card>"
  )

  attr(:mode, :atom,
    default: :preview,
    values: [:preview, :full],
    doc: "see <.remote_post_card> — `:full` is the answering page, which is about this one reply"
  )

  def remote_reply_card(assigns) do
    note = assigns.note
    translation = card_translation(assigns, {:note, note.id}, note.content_text, note.language)

    assigns =
      assigns
      |> assign(:translation, translation)
      |> assign(:body_id, "remote-reply-body-#{note.id}")
      |> assign(:body_style, post_body_style(User.post_prefs(assigns.viewer)))
      |> assign(:author, Note.label(note))
      |> assign(:handle, Note.display_handle(note))
      |> assign(:host, Note.host(note.actor_uri))
      |> assign(:origin, Note.origin(note))
      |> assign(:initials, name_initials(Note.author_name(note) || note.handle))
      |> assign(:public?, Note.public?(note))
      |> assign(:warned?, Note.warned?(note))

    ~H"""
    <%!-- The `id` is this reply's anchor: it has no permalink of its own, so a
    link to one (the notification quote) is the conversation's URL plus this
    fragment. `scroll-mt-24` keeps the sticky top bar from parking over the card
    the reader was sent to, the same allowance a footnote target gets. --%>
    <article
      data-fediverse-reply={@note.id}
      data-audience={@note.audience}
      id={Fediverse.reply_anchor(@note.id)}
      class="scroll-mt-24"
    >
      <%!-- Why this reply is in the reader's feed: somebody they follow here
      passed it on (issue #1275). The same line a reshared post wears, so
      "somebody carried this to you" reads identically whatever was carried. --%>
      <.reshare_line
        :if={@reposted_by}
        name={full_name(@reposted_by)}
        navigate={~p"/#{@reposted_by.username}"}
        data-reshared-reply
      />
      <div class="flex items-start gap-3">
        <.remote_avatar initials={@initials} />

        <div class="min-w-0 flex-1">
          <.remote_header
            author={@author}
            handle={@handle}
            actor_uri={@note.actor_uri}
            at={@note.received_at}
            account_id={@note.account_id}
          >
            <:menu>
              <%!-- The takedown controls. Report is open to anyone who can see the
              reply (which for a private one is its addressee alone) and deletes it
              at once — no case workflow, because this is a cache of something that
              still exists at its origin. --%>
              <.card_menu :if={@viewer} id={"remote-reply-menu-#{@note.id}"}>
                <:item
                  :if={@owner?}
                  click="remove-remote-reply"
                  value={@note.id}
                  confirm={gettext("Remove this reply from your post?")}
                >
                  {gettext("Remove")}
                </:item>
                <:item
                  click="report-remote-reply"
                  value={@note.id}
                  danger
                  confirm={
                    gettext("Report this reply as not appropriate? It is deleted right away.")
                  }
                >
                  {gettext("Report")}
                </:item>
              </.card_menu>
            </:menu>
          </.remote_header>

          <%!-- A reply addressed to the member alone (issue #1071). The lock is
          the same glyph a restricted post wears, so "not everybody sees this"
          reads the same way across the app — and the member must know it before
          they answer as if the world were watching. --%>
          <.remote_restricted_note :if={!@public?}>
            {gettext("Sent to you only, visible to nobody else")}
          </.remote_restricted_note>

          <.remote_body
            warning={@warned? && translated_summary(@translation, @note.summary)}
            text={@translation.body_source}
            lang={@translation.lang}
            mode={@mode}
            body_id={@body_id}
            body_style={@body_style}
          />

          <.translation_line
            state={@translation.state}
            offer?={@translation.offer?}
            kind="note"
            subject_id={@note.id}
          />

          <%!-- The card's acts, in the open under the body where a reader
          looks for them (issues #1270, #1275, #1276). The bar owns its own
          state and its own events, so this card — and every host that renders
          it — hands it the subject and nothing else. `live?` is false on a dead
          controller page, where a LiveComponent cannot render and its buttons
          would do nothing anyway, and on the answering page, where this card is
          the read-only thing being answered. --%>
          <.live_component
            :if={@live? and @viewer}
            module={RemoteActionsComponent}
            id={RemoteActionsComponent.dom_id(@note)}
            subject={@note}
            viewer={@viewer}
            marks={@marks}
          />

          <.remote_footer host={@host} origin={@origin} label={gettext("View the original")} />
        </div>
      </div>
    </article>
    """
  end

  # ## The remote skin
  #
  # The four pieces every card for content from another network is built from,
  # so "this did not come from vutuv" — the slate initials tile with its globe
  # badge, the lock line, the body with its content-warning lid, the
  # origin footer — has ONE definition and reads identically wherever it
  # appears. `remote_reply_card/1` (a reply under a member's post) and
  # `remote_post_card/1` (a post by a followed account) differ only in which
  # struct feeds them, which controls their menu carries and what their footer
  # link says; the look is not theirs to vary.

  attr(:initials, :string, required: true)

  attr(:size, :string,
    default: "sm",
    values: ~w(sm lg),
    doc: "`lg` for the account page's header, where the tile is the page's subject"
  )

  attr(:src, :any, default: nil, doc: "the cached avatar's URL, when the gate has cleared one")

  @doc """
  The slate initials tile with its globe badge — "this did not come from
  vutuv", in one definition. Public so the account page
  (`VutuvWeb.FediverseAccountLive`) wears the same skin as the cards: that page
  is where a reader decides about a stranger, so it is the last place the badge
  should be missing.
  """
  def remote_avatar(assigns) do
    ~H"""
    <span class="relative shrink-0">
      <%!-- The account's own picture once it is stored AND the AI gate has
      cleared it (issue #1163); initials until then, and for good if it never
      is. `RemoteAccount.avatar_ready?/1` is the one chokepoint, so "we have a
      file" can never drift from "we were allowed to show it" — and a
      picture-less remote account reads exactly like a picture-less member. --%>
      <img
        :if={@src}
        src={@src}
        alt=""
        data-remote-avatar
        loading="lazy"
        class={[
          "inline-block rounded-full object-cover",
          @size == "lg" && "h-14 w-14",
          @size == "sm" && "h-9 w-9"
        ]}
      />
      <span
        :if={is_nil(@src)}
        data-remote-avatar
        aria-hidden="true"
        class={[
          "inline-flex select-none items-center justify-center rounded-full bg-slate-200 font-semibold text-slate-600 dark:bg-slate-700 dark:text-slate-300",
          @size == "lg" && "h-14 w-14 text-base",
          @size == "sm" && "h-9 w-9 text-xs"
        ]}
      >
        {@initials}
      </span>
      <span
        aria-hidden="true"
        title={gettext("From another network")}
        class="absolute -bottom-1 -left-1 flex h-4 w-4 items-center justify-center rounded-full bg-white text-[9px] ring-2 ring-white dark:bg-slate-900 dark:ring-slate-900"
      >
        🌐
      </span>
    </span>
    """
  end

  attr(:author, :string, required: true)
  attr(:handle, :string, required: true)
  attr(:actor_uri, :string, required: true)
  attr(:at, :any, required: true, doc: "the stamp the card shows for this content")

  attr(:network, :any,
    default: nil,
    doc: "the server, shown as a chip when the card's position does not say where it came from"
  )

  attr(:account_id, :any,
    default: nil,
    doc: "the stored account row, when we know it: the handle then links to its page here"
  )

  attr(:permalink, :any,
    default: nil,
    doc:
      "our own page for this content, which the stamp then links to like a member post's does; nil leaves the stamp plain text"
  )

  attr(:origin, :any,
    default: nil,
    doc:
      "the content's own address on its server, which the host chip then links to; nil leaves the chip plain text"
  )

  slot(:menu)

  # `break-words` on the author and the handle is not cosmetic: both come
  # straight from a remote actor document and may be 255 characters with no
  # space in them. Without it a single unbreakable token sets the row's
  # min-content, and on a phone that scrolls the whole page sideways and pushes
  # the ⋯ menu off the viewport — taking Report with it, on exactly the post
  # most likely to need it.
  #
  # The handle is shown **without its server** (`Handle.short/1`): the globe chip
  # in this very row already names the server, so `@tagesschau@ard.social`
  # said it twice and ate the width the stamp needed. The full address stays as
  # the link's `title`, which is also what a member wants to read before they
  # paste it somewhere.
  #
  # The row reads **name, handle, server chip, stamp** — who, their address,
  # where that address lives, when. The chip stands between the handle and the
  # stamp rather than beside the name (Stefan, 2026-08-01): `@tagesschau` and
  # `ard.social` are one address read in two parts, and splitting them around
  # the name made the eye assemble it backwards.
  #
  # Four things wrap in that row and on a phone they do not all fit, so the
  # `gap-y` is load-bearing: `gap-x-2` sets no vertical gap at all, and a
  # wrapped pill then sits hard against the line above it, which is how issue
  # #1284 was reported. For the same reason there is **no `·` before the
  # stamp** any more: with the handle and the stamp in one span it separated
  # them, but as four independent flex items a wrapped line began with a lonely
  # dot that read as a bullet. The gap does that work now, exactly as on a
  # member's post card, whose header has never carried one.
  # `feed_remote_posts_test.exs` fails the build if the order changes or the
  # row loses its `gap-y`.
  defp remote_header(assigns) do
    ~H"""
    <div class="flex items-start gap-2">
      <div
        data-remote-header
        class="flex min-w-0 flex-1 flex-wrap items-baseline gap-x-2 gap-y-1"
      >
        <span data-remote-author class="break-words font-semibold text-slate-900 dark:text-white">
          {@author}
        </span>
        <.link
          {remote_actor_destination(@account_id, @actor_uri)}
          data-remote-account={@account_id}
          data-remote-handle={@handle}
          title={@handle}
          class="min-w-0 break-all text-xs hover:text-brand-700 dark:hover:text-brand-300 sm:break-normal"
        >{Handle.short(@handle)}</.link>
        <%!-- Where this came from, up here where the eye lands, not in a line
        under the text. A reply card can carry that line because it is visibly
        indented under a member's post; in a flat feed that context is gone, and
        a reader must not have to finish the post before learning it is not a
        member's. --%>
        <.remote_network_chip :if={@network} network={@network} origin={@origin} />
        <span data-remote-stamp class="text-xs text-slate-600 dark:text-slate-400">
          <%!-- The stamp is the way to this post's own page here, exactly as on a
          member's card. Only where we have such a page: a reply from another
          network has none, and a reader who is not signed in cannot open the one
          a cached post has. --%>
          <.link
            :if={@permalink}
            navigate={@permalink}
            data-remote-permalink
            class="hover:text-brand-700 dark:hover:text-brand-300"
          >
            <.post_time at={@at} />
          </.link>
          <.post_time :if={!@permalink} at={@at} />
        </span>
      </div>
      {render_slot(@menu)}
    </div>
    """
  end

  attr(:network, :string, required: true)
  attr(:origin, :any, default: nil)

  # The server this came from, and — where we have the content's own address —
  # the way to it. One control instead of two: the chip was already the answer
  # to "where is this from", and "and take me there" is the same question asked
  # one step further, so the provenance footer that used to repeat the host and
  # append a "View the original" link is gone (Stefan, 2026-08-01). A card with
  # no viewer (the public tag timeline: no ⋯ menu, no permalink on the stamp)
  # keeps its way out this way, which is why the chip carries the link and not
  # only the menu.
  defp remote_network_chip(assigns) do
    ~H"""
    <.link
      :if={@origin}
      href={@origin}
      target="_blank"
      rel="nofollow noopener noreferrer"
      data-remote-network={@network}
      data-remote-origin
      title={gettext("View the original")}
      class={[network_chip_class(), "hover:bg-slate-200 dark:hover:bg-slate-700"]}
    >
      <span aria-hidden="true">🌐</span>
      <span class="truncate">{@network}</span>
    </.link>
    <span :if={!@origin} data-remote-network={@network} class={network_chip_class()}>
      <span aria-hidden="true">🌐</span>
      <span class="truncate">{@network}</span>
    </span>
    """
  end

  # The chip's own look, shared by its two shapes so a linked and an unlinked
  # one are the same pill. The slate text colour is spelled out because
  # `components.css` colours a bare `a` brand-600, which would otherwise turn
  # the linked chip into a blue pill.
  defp network_chip_class do
    "inline-flex max-w-full items-center gap-1 rounded-full bg-slate-100 px-2 py-0.5 text-[11px] font-medium text-slate-600 dark:bg-slate-800 dark:text-slate-300"
  end

  # Where a remote handle leads, as the attributes to splat onto a `<.link>`.
  #
  # Inward when we know the account (issue #1162): the handle is the thing a
  # reader taps to ask "who is this", and the answer to that is a page here
  # where they can see what the account posts and follow it — not a trip off
  # the site to somebody else's server. The link out is still one click away,
  # in the footer. Straight out when we do not know them, since there would be
  # nothing to show.
  #
  # One definition, because the header of every remote card and the reaction
  # chips ask the same question, and a chip that answered it differently from
  # the card above it would be the same handle leading two places.
  defp remote_actor_destination(nil, actor_uri),
    do: [href: actor_uri, target: "_blank", rel: "nofollow noopener noreferrer"]

  defp remote_actor_destination(account_id, _actor_uri),
    do: [navigate: ~p"/system/fediverse/account/#{account_id}"]

  # The lock line. The same glyph a restricted vutuv post wears, so "not
  # everybody sees this" reads the same way across the app; the sentence is the
  # caller's, since who "everybody" excludes differs.
  slot(:inner_block, required: true)

  defp remote_restricted_note(assigns) do
    ~H"""
    <p
      data-remote-private
      class="mb-0 mt-0.5 text-xs font-medium text-slate-600 dark:text-slate-400"
    >
      <span aria-hidden="true">🔒</span> {render_slot(@inner_block)}
    </p>
    """
  end

  # The body text, reading like any post body — the avatar badge, the host chip
  # and the origin footer say where it came from, so the text is not set apart
  # as if it were a quotation (the dashed rail it once wore read as an
  # unexplained decoration). `warning` set (a content warning, or the author's
  # sensitive flag) closes the lid: the text hides behind a click, which is the
  # one thing that author asked for.
  attr(:warning, :any, default: nil)
  attr(:text, :string, required: true)

  # The body is the stored **plain text** (`Vutuv.RemoteHtml` reduced the remote
  # HTML at the inbox), formatted for reading by
  # `VutuvWeb.Markdown.render_remote/1` — the same renderer the Mastodon feed on
  # the profile uses, so remote text reads one way across the app. What that
  # buys here is mostly the thing a bare `whitespace-pre-line` paragraph got
  # wrong: a post on those networks is largely *links*, and they sat on the card
  # as raw unclickable strings that wrapped mid-URL. Now they autolink with a
  # truncated display, `#hashtags` reach our tag pages (only where the tag is
  # non-empty) and a `@user@host` handle reaches that remote account.
  #
  # It stays inside a foreign namespace, which is what `render_remote/1` is for
  # and why the plain renderer is still the wrong one: every `<img>` is dropped
  # (a hotlink would leak each reader's IP), and a bare `@mention` deliberately
  # stays plain text — over there it names an account in the fediverse, not the
  # member here who happens to share the handle. The output is sanitized exactly
  # like a member post's, so `raw/1` on it is the same `raw/1` every post body
  # gets.
  #
  # `.markdown` carries the wrapper's `overflow-wrap: break-word` for the same
  # reason the header has `break-words`: this is a stranger's text, up to 10,000
  # characters, and nothing stops it being one unbroken token.
  #
  # The lid is a real touch target (`min-h-10`) and says both things: "Show"
  # while it is closed, "Hide" once it is open — a lid you cannot shut again is
  # not a lid.
  #
  # The closing hashtag line is lifted out of the text first
  # (`Markdown.split_trailing_hashtags/1`) and rendered as chips below, so a
  # post from over there wears its tags the way a member's post does. A warned
  # post keeps its chips **inside** the lid: the tags of a post its author put
  # behind a content warning are part of what they covered up.
  #
  # `data-nosnippet` on the wrapper because this card also shows up on pages a
  # crawler reads: a public tag timeline lists cached remote posts, and a member
  # who reshares one puts it on their profile. The page stays indexable — it is
  # ours, and the remote card is one entry on it — but the passage a search
  # result quotes under our URL must come from our own content, not from a
  # sentence somebody wrote on another server. Google honors the attribute on a
  # `div`/`span`/`section` and covers its descendants, so the one wrapper takes
  # the warning, the body and the chips with it.
  # The body's language (BCP47 primary subtag) for the `lang` attribute;
  # nil renders no attribute.
  attr(:lang, :string, default: nil)

  # `:preview` (a feed, a profile, a tag timeline) cuts the body to the reader's
  # own line budget and offers the in-place "Read more" a member's post already
  # gets — the same clamp, the same hook, the same control, so a long post from
  # another network costs the timeline what a long post from here costs and no
  # reader has to learn a second way to open one. Text is all these cards ever
  # hold (`render_remote/1` drops every image), so the plain line clamp fits
  # unless a link screenshot floats beside it. `:full` renders the body whole,
  # for the pages that ARE this one post.
  attr(:mode, :atom, default: :preview, values: [:preview, :full])
  attr(:body_id, :string, default: nil, doc: "the clamp body's DOM id; :preview needs one")
  attr(:body_style, :string, default: nil, doc: "the reader's --post-clamp-* override, or nil")

  # The auto link screenshot, when the card has one. It has to render INSIDE
  # the clamp block, as its first child: a float placed outside a height-clamped
  # `flow-root` box is not wrapped by the text at all, it narrows the whole box.
  slot(:float)

  defp remote_body(assigns) do
    {text, hashtags} = Markdown.split_trailing_hashtags(assigns.text)

    assigns =
      assigns
      |> assign(:body?, presence?(text))
      |> assign(:html, Markdown.render_remote(text))
      |> assign(:tags, remote_tag_chips(hashtags))

    ~H"""
    <div :if={@warning || @body? || @tags != []} data-nosnippet class="mt-1.5">
      <%= if @warning do %>
        <details data-remote-warning class="group">
          <summary class="flex min-h-10 cursor-pointer list-none items-center gap-1 text-sm font-medium text-slate-700 dark:text-slate-300">
            <span aria-hidden="true">⚠</span>
            <span class="min-w-0 break-words">{@warning}</span>
            <span class="text-xs font-normal text-brand-600 group-open:hidden dark:text-brand-400">
              {gettext("Show")}
            </span>
            <span class="hidden text-xs font-normal text-brand-600 group-open:inline dark:text-brand-400">
              {gettext("Hide")}
            </span>
          </summary>
          <%!-- A warned post is clamped inside its own lid: the reader opened it
          to read the text, not to be handed ten thousand characters of it. The
          measurement runs on the `toggle` sweep in app.js, since a closed
          `<details>` paints nothing and cannot be measured while shut. --%>
          <.remote_prose
            :if={@body?}
            html={@html}
            lang={@lang}
            mode={@mode}
            body_id={@body_id}
            body_style={@body_style}
            class="mt-1.5"
          />
          <.remote_tags tags={@tags} />
        </details>
      <% else %>
        <.remote_prose
          :if={@body?}
          html={@html}
          lang={@lang}
          mode={@mode}
          body_id={@body_id}
          body_style={@body_style}
        >
          <:float :for={float <- @float}>{render_slot(float)}</:float>
        </.remote_prose>
        <.remote_tags tags={@tags} />
      <% end %>
    </div>
    """
  end

  # The skin a stranger's words wear wherever they appear: a size down from a
  # member's post and a shade quieter. One definition, so a clamped remote body
  # and a whole one cannot drift into two different types — and in `:preview` it
  # rides the WRAPPER, never the clamp body (see `<.preview_body>`'s `class`).
  defp remote_prose_class, do: "text-sm text-slate-700 dark:text-slate-300"

  # The remote body's prose. `:preview` routes it through the shared
  # `<.preview_body>` — the same wrapper, hook, fade and "Read more" a member's
  # post gets — so there is one clamp mechanism in the app and not two.
  attr(:html, :any, required: true)
  attr(:lang, :string, default: nil)
  attr(:mode, :atom, default: :preview, values: [:preview, :full])
  attr(:body_id, :string, default: nil)
  attr(:body_style, :string, default: nil)
  attr(:class, :string, default: nil)
  slot(:float)

  defp remote_prose(%{mode: :full} = assigns) do
    ~H"""
    <%!-- The float rides inside the body, whose `.markdown--post::after`
    clearfix keeps a tall shot from spilling past the text into the action bar
    below — the same place full mode puts a member post's screenshot. --%>
    <div lang={@lang} class={["markdown markdown--post", remote_prose_class(), @class]}>
      {render_slot(@float)}
      {Phoenix.HTML.raw(@html)}
    </div>
    """
  end

  defp remote_prose(assigns) do
    ~H"""
    <.preview_body
      body_id={@body_id}
      body_html={Phoenix.HTML.raw(@html)}
      body_style={@body_style}
      class={[remote_prose_class(), @class]}
      lang={@lang}
      wrap={@float != []}
    >
      <:float :for={float <- @float}>{render_slot(float)}</:float>
    </.preview_body>
    """
  end

  # The hashtags a remote post closed with, as the same brand-tint `<.chip>`
  # row a member's post gets for its tags — the whole point of lifting them out
  # of the text (`Markdown.split_trailing_hashtags/1`): one tag vocabulary,
  # rendered one way, wherever a post came from.
  #
  # Down to the gap above the row, which is `<.post_tags>`'s `mt-3` and not a
  # tighter one of its own: the two cards sit one under the other in the same
  # feed column, so a row 4px closer to the last line does not read as "this
  # one came from elsewhere", it reads as a card that got its spacing wrong.
  # It showed most where a post ends on a link, which is where the eye already
  # sits low in the line.
  attr(:tags, :list, required: true)

  defp remote_tags(assigns) do
    ~H"""
    <div :if={@tags != []} data-remote-tags class="mt-3 flex flex-wrap gap-2">
      <.chip :for={tag <- @tags} navigate={tag.path} data-remote-tag={tag.name}>{tag.name}</.chip>
    </div>
    """
  end

  # A chip links to `/tags/:slug` on exactly the same gate the inline
  # `#hashtag` uses (`Tags.linkable_slugs/1`: the tag exists here and has at
  # least one visible member), so a pill never lands on an empty tag page. One
  # query for the whole row — and the body it came out of is now one hashtag
  # lighter, so this costs the card no extra lookup.
  #
  # A tag we do not carry still gets its chip, as a plain span: dropping it
  # would silently swallow part of what the author wrote, and rendering it
  # differently would say something about the tag that is really about us.
  defp remote_tag_chips([]), do: []

  defp remote_tag_chips(hashtags) do
    linkable = Tags.linkable_slugs(hashtags)

    Enum.map(hashtags, fn hashtag ->
      # The slug we link is the one the gate hands back, which is the canonical
      # tag's when the remote server wrote an alternative name (issue #1338).
      slug = Map.get(linkable, String.downcase(hashtag))
      %{name: hashtag, path: slug && ~p"/tags/#{slug}"}
    end)
  end

  @doc """
  The action row **both** cards from another network wear — a reply under a
  member's post and a cached post by a followed account (issues #1270, #1275
  and #1276).

  One definition, because "what can I do with this" is exactly what must not
  differ between the two: to a reader they are the same kind of object, and a
  heart that is a button on one card and a footnote on the other is a bug
  waiting to be reported. It was, twice — first as "I have no way to like or
  answer the answer on that page", then as "and what about the repost and
  bookmark?".

  The order is the local action bar's: like, reply, repost, bookmark. Each
  control renders only where the act exists at all, which is a fact about the
  **subject**, never about the reader:

    * **like** — needs an address to deliver to (`like?`); a reply stored before
      issue #1070 carries none.
    * **reply** and **repost** — public subjects only (`reply_to`, `repost?`).
      An answer is a public vutuv post and a reshare is publishing, and passing
      on an audience its author narrowed is not ours to do, so there is no
      control rather than one that refuses.
    * **bookmark** — always, for any signed-in reader. The one act that stays
      here: nothing is sent and nothing is addressed, so it asks nothing of the
      member's Fediverse standing.

  Everything the reader *is* — federating or not, moved, on a server the
  operator blocked — is deliberately **not** asked here. Those controls render
  and the press explains itself, because hiding them leaves a member no way to
  find out the capability exists (issue #1070's rule, applied to all four).

  `kind` names the events, so one row drives two hosts: `"remote-reply"` gives
  `like-remote-reply` / `unlike-remote-reply` and so on, `"remote-post"` the
  `…-remote-post` pairs the feed and the account page already handle.
  """
  attr(:id, :string, required: true, doc: "the bar's own id, which the controls key off")
  attr(:target, :any, required: true, doc: "the RemoteActionsComponent that handles the presses")
  attr(:subject_id, :string, required: true, doc: "rides every control as phx-value-id")
  attr(:viewer, :any, default: nil, doc: "the logged-in member, or nil for no row at all")
  attr(:liked?, :boolean, default: false)
  attr(:reposted?, :boolean, default: false)
  attr(:bookmarked?, :boolean, default: false)

  attr(:standing_ok?, :boolean,
    default: false,
    doc:
      "`Vutuv.Fediverse.outbound_standing/1` said `:ok`, so a like or a reshare may paint on press"
  )

  attr(:reset, :integer,
    default: 0,
    doc:
      "bumped by the bar when an act was refused; changes the controls' ids, see `control_id/3`"
  )

  attr(:likes, :integer,
    default: nil,
    doc: "the origin's own like tally; nil when it does not serve one"
  )

  attr(:shares, :integer, default: nil, doc: "the origin's own repost tally, or nil")
  attr(:like?, :boolean, default: true, doc: "false where a Like could not be delivered at all")
  attr(:reply_to, :any, default: nil, doc: "the answering page's path, or nil/false for none")
  attr(:repost?, :boolean, default: false)

  def remote_actions(assigns) do
    ~H"""
    <%!-- The local action bar's own geometry, deliberately to the pixel
    (`post_actions/1` above): `justify-between` spreads the controls across the
    column's full width, `-mx-2` cancels the outer buttons' `px-2` so the first
    and last glyphs line up with the column edges, and every control is the
    same icon-only rounded target with the same hover fill. A post from another
    network is a post; a reader should not have to learn a second bar for it.
    That it once read as icon-plus-label, huddled at the left, was reported as
    exactly that: "das soll alles einheitlich sein". --%>
    <div
      :if={@viewer}
      class="-mx-2 mt-3 flex items-center justify-between gap-2 text-slate-600 dark:text-slate-400"
    >
      <%!-- The heart and the reshare carry a number, and it is the **origin's
      own**, not a tally of what happened to pass through this installation
      (issue #1283): the object's `likes` and `shares` collections, asked for in
      the background and refreshed while the post is new. A `nil` — the servers
      that serve neither collection — renders no figure at all rather than a
      `0`, which would be a claim we cannot make on somebody else's behalf.
      Reply and bookmark stay bare: a remote reply tally is not served in a form
      we can trust, and a bookmark is private and local. --%>
      <.remote_action
        :if={@like?}
        id={control_id(@id, "like", @reset)}
        act="like"
        target={@target}
        subject_id={@subject_id}
        on?={@liked?}
        on_class="text-accent"
        on_label={gettext("Unlike")}
        off_label={gettext("Like")}
        count={@likes}
        optimistic?={@standing_ok?}
        filled?
      >
        <.icon_heart filled?={@liked?} />
      </.remote_action>

      <%!-- A link, not a toggle: answering opens its own page, which is where a
      member who does not federate yet is told so before they type. --%>
      <.remote_action_link
        href={@reply_to}
        subject_id={@subject_id}
        label={gettext("Reply")}
        shown={@reply_to}
      >
        <.icon_reply />
      </.remote_action_link>

      <.remote_action
        :if={@repost?}
        id={control_id(@id, "repost", @reset)}
        act="repost"
        target={@target}
        subject_id={@subject_id}
        on?={@reposted?}
        on_class="text-brand-600 dark:text-brand-300"
        on_label={gettext("Undo repost")}
        off_label={gettext("Repost")}
        count={@shares}
        optimistic?={@standing_ok?}
      >
        <.icon_repost />
      </.remote_action>

      <%!-- Saving is the one act here that never leaves the building, so it
      never asks after anybody's Fediverse standing (`check_bookmark/2` asks
      only whether the reader may read this) and paints on press for everyone,
      the member who does not federate included. --%>
      <.remote_action
        id={control_id(@id, "bookmark", @reset)}
        act="bookmark"
        target={@target}
        subject_id={@subject_id}
        on?={@bookmarked?}
        on_class="text-brand-600 dark:text-brand-300"
        on_label={gettext("Remove bookmark")}
        off_label={gettext("Bookmark")}
        optimistic?
        filled?
      >
        <.icon_bookmark filled?={@bookmarked?} />
      </.remote_action>
    </div>
    """
  end

  # One control in that bar. `shown` decides whether it is rendered or merely
  # **held open** as an invisible placeholder: the four controls are spread by
  # `justify-between`, so dropping one would slide the rest along the row and the
  # bars on two neighbouring cards would no longer line up — which is half of
  # what made the fediverse card look like a different component. An act this
  # card cannot carry keeps its slot and gives up its glyph.
  attr(:id, :string, default: nil)
  attr(:act, :string, required: true, values: ~w(like repost bookmark))
  attr(:target, :any, required: true)
  attr(:subject_id, :string, required: true)
  attr(:on?, :boolean, required: true)
  attr(:on_class, :string, required: true)
  attr(:on_label, :string, required: true)
  attr(:off_label, :string, required: true)
  attr(:shown, :any, default: true)
  attr(:count, :integer, default: nil, doc: "the origin's figure, or nil for no figure at all")

  attr(:optimistic?, :boolean,
    default: false,
    doc: "paint the press on the spot rather than waiting for the answer"
  )

  attr(:filled?, :boolean, default: false, doc: "the glyph fills while active (heart, bookmark)")
  slot(:inner_block, required: true)

  defp remote_action(%{shown: shown} = assigns) when shown in [nil, false] do
    ~H"""
    <span aria-hidden="true" class="inline-flex px-2 py-1"><span class="h-5 w-5"></span></span>
    """
  end

  defp remote_action(assigns) do
    assigns =
      assigns
      |> assign(:label, if(assigns.on?, do: assigns.on_label, else: assigns.off_label))
      |> assign(:idle_class, @idle_action_class)

    ~H"""
    <button
      type="button"
      id={@id}
      phx-click={remote_toggle_js(@optimistic?, @on_class, @on_label, @off_label)}
      phx-target={@target}
      phx-value-act={@act}
      aria-pressed={to_string(@on?)}
      aria-label={@label}
      title={@label}
      data-remote-act={@act}
      data-remote-id={@subject_id}
      data-on={@on? && "on"}
      data-awaits-server={!@optimistic? && "true"}
      data-count-steps
      data-fills-when-pressed={@filled? && "true"}
      class={[
        "inline-flex items-center gap-1.5 rounded-lg px-2 py-1 text-sm hover:bg-slate-100 dark:hover:bg-slate-800",
        # components.css colors bare `a, button` brand-600, which beats the
        # wrapper's inherited slate — so the state color sits on the button.
        if(@on?, do: @on_class, else: @idle_class)
      ]}
    >
      {render_slot(@inner_block)}
      <.remote_count count={@count} act={@act} on?={@on?} />
    </button>
    """
  end

  # The same flip the vutuv bar does (`toggle_js/4`, and the absolute-state rule
  # in its comment applies here word for word), but only where the press is
  # going to succeed. `optimistic?` is false for a member whose own standing
  # already refuses the act — `Vutuv.Fediverse.outbound_standing/1`, asked once
  # per bar and free of queries — because Fediverse participation is opt-in and
  # most readers have not switched it on while remote posts reach their feed
  # anyway. For them a heart that fills and empties again on every single press
  # is worse than the explanation the bar prints instead, so their button keeps
  # waiting for the server.
  defp remote_toggle_js(false, _on_class, _on_label, _off_label), do: "toggle"

  defp remote_toggle_js(true, on_class, on_label, off_label) do
    JS.push("toggle")
    |> JS.toggle_class("#{on_class} #{@idle_action_class}")
    |> JS.toggle_attribute({"aria-pressed", "true", "false"})
    |> JS.toggle_attribute({"aria-label", on_label, off_label})
    |> JS.toggle_attribute({"title", on_label, off_label})
    |> JS.toggle_attribute({"data-on", "on"})
  end

  # The origin's figure beside a glyph, in the local bar's own `count_pill`
  # geometry. Two silences that look alike and are not: a `nil` is "this server
  # tells us nothing", a `0` is "it says nobody has". Both render blank — but the
  # zero keeps a mounted, invisible span, so the first arriving count does not
  # shift the neighbouring glyphs under the pointer, exactly as on a member's
  # post.
  attr(:count, :integer, default: nil)
  attr(:act, :string, required: true)
  attr(:on?, :boolean, required: true)

  defp remote_count(%{count: nil} = assigns) do
    ~H""
  end

  # Both steps of the origin's figure, pre-rendered the way the vutuv bar
  # pre-renders its own (`toggle_count/1`): what it reads while the reader has
  # not acted, and what it reads once they have. `max(count - 1, 0)` matches the
  # bar's own `step/2`, which is what actually moves the stored figure, so the
  # painted number and the one that survives a reload are the same number.
  defp remote_count(assigns) do
    assigns =
      assigns
      |> assign(:off, if(assigns.on?, do: max(assigns.count - 1, 0), else: assigns.count))
      |> assign(:on, if(assigns.on?, do: assigns.count, else: assigns.count + 1))

    ~H"""
    <span
      data-count-off
      class={["font-medium tabular-nums", @off == 0 && "invisible"]}
      data-remote-count={!@on? && @act}
    >{compact_count(@off)}</span>
    <span data-count-on class="font-medium tabular-nums" data-remote-count={@on? && @act}>{compact_count(@on)}</span>
    """
  end

  @doc false
  # A control's DOM id, and with it morphdom's key for the node. It carries the
  # bar's refusal counter, which is the only way the server can take an
  # optimistic paint back: LiveView stashes each JS class/attribute op on the
  # element and re-applies it after every patch, and nothing ever expires it
  # (`DOM.putSticky` / `applyStickyOperations`; `deleteSticky` has no caller).
  # A patch therefore cannot overrule the client — but a node morphdom has never
  # seen is created fresh, stash and all. So on a refusal the bar bumps the
  # counter, the id changes, the painted node is discarded and the server's
  # truth renders in its place.
  #
  # Zero leaves the id exactly as it was before any of this, which is what keeps
  # every selector and test keyed on `#…-like` working: the suffix only ever
  # appears after something was actually refused.
  def control_id(base, kind, 0), do: "#{base}-#{kind}"
  def control_id(base, kind, reset), do: "#{base}-#{kind}-r#{reset}"

  # The answering control: the same slot and the same look, but a link.
  attr(:href, :any, required: true)
  attr(:subject_id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:shown, :any, default: true)
  slot(:inner_block, required: true)

  defp remote_action_link(%{shown: shown} = assigns) when shown in [nil, false] do
    ~H"""
    <span aria-hidden="true" class="inline-flex px-2 py-1"><span class="h-5 w-5"></span></span>
    """
  end

  defp remote_action_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      aria-label={@label}
      title={@label}
      data-remote-reply-link={@subject_id}
      class="inline-flex items-center gap-1.5 rounded-lg px-2 py-1 text-sm text-slate-600 hover:bg-slate-100 dark:text-slate-400 dark:hover:bg-slate-800"
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  # Where it came from and the way on to the real thing — provenance, not
  # actions: both remote cards' acts live in their own row above this line
  # (issue #1270). The inner block is what a card needs to add to the
  # provenance itself.
  attr(:host, :any, default: nil)
  attr(:origin, :string, required: true)
  attr(:label, :string, required: true)
  attr(:rest, :global)
  slot(:inner_block)

  defp remote_footer(assigns) do
    ~H"""
    <p class="mb-0 mt-1.5 break-words text-xs text-slate-600 dark:text-slate-400">
      {gettext("From another network")}<span :if={@host}> · {@host}</span> ·
      <a
        href={@origin}
        target="_blank"
        rel="nofollow noopener noreferrer"
        class="font-medium text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
        {@rest}
      >{@label}</a>
      {render_slot(@inner_block)}
    </p>
    """
  end

  attr(:account, :map, required: true)

  @doc """
  Why a card is in the reader's feed when they follow neither its author nor
  anybody here who shared it: an account they **do** follow out there re-shared
  it (issue #1167).

  The very same line the local reshare wears (`reshare_line/1` below), so
  "somebody passed this on" reads identically whichever world did the passing.
  The underlying author keeps their own attribution in the header below — this
  line names the messenger, never the writer.
  """
  def boosted_banner(assigns) do
    ~H"""
    <%!-- Name **and** handle, unlike the local line beside it. A display name
    on a remote account is whatever that server lets somebody type, and this
    banner is the only thing on the card explaining why a stranger's post is in
    the reader's feed — "Repostet von Stefan Wintermeyer" with no address would
    read as the member of that name. Every other surface pairs the two for the
    same reason. --%>
    <.reshare_line
      name={"#{RemoteAccount.label(@account)} (#{RemoteAccount.display_handle(@account)})"}
      navigate={~p"/system/fediverse/account/#{@account.id}"}
      data-boosted-by={@account.id}
    />
    """
  end

  attr(:name, :string, required: true)
  attr(:navigate, :any, default: nil, doc: "in-app destination (a remote account page)")
  attr(:href, :any, default: nil, doc: "full-navigation destination (a member's profile)")
  attr(:rest, :global)

  # "Reposted by NAME" over the post it carries: the one markup for both worlds,
  # a member here resharing a cached post (issue #1166) and an account the
  # reader follows out there boosting one (issue #1167). Pass whichever of
  # `navigate` / `href` the destination needs.
  defp reshare_line(assigns) do
    ~H"""
    <p
      class="mb-3 flex items-center gap-2 text-xs font-semibold text-slate-600 dark:text-slate-400"
      {@rest}
    >
      <.icon_repost class="h-4 w-4 shrink-0" />
      <.link navigate={@navigate} href={@href} class="min-w-0 truncate hover:text-brand-700 dark:hover:text-brand-300">
        {gettext("Reposted by %{name}", name: @name)}
      </.link>
    </p>
    """
  end

  attr(:images, :list, default: [])

  @doc """
  The pictures on a post from another network (issue #1163).

  **Unreleased ones reach here too.** `Vutuv.Fediverse.list_remote_images/1`
  deliberately does not filter on the AI gate (this doc claimed the opposite
  until issue #1801, while the waiting tile below was already the proof), so
  `RemoteImage.released?/1` is asked here, per picture, and the tile is what a
  reader gets meanwhile.

  The gate is one of two independent conditions, and the second is this
  component's own: a picture its **author** flagged sensitive, or one under
  their content warning, renders blurred behind a click. That is deliberately
  not overridable by our verdict — our model judging a picture safe does not
  overrule the person who published it asking for it to be covered.

  The alt text is the author's own, kept through the whole journey, because it
  is the only thing that makes the picture readable to somebody who cannot see
  it. A picture with none gets an empty alt rather than an invented one: an
  unlabelled image is honest, a made-up label is not.
  """
  def remote_post_images(assigns) do
    # Only the pictures that are really still being looked at. A picture that is
    # not coming is `not released?` too, and counting it here is what put the
    # "our AI is looking at it" line under cards whose picture had been refused
    # three weeks earlier (issue #1803).
    assigns =
      assign(
        assigns,
        :held_count,
        Enum.count(assigns.images, &(RemoteImage.display_state(&1) == :waiting))
      )

    ~H"""
    <div
      :if={@images != []}
      data-remote-images={length(@images)}
      class={[
        "mt-2 grid gap-2",
        length(@images) > 1 && "grid-cols-2"
      ]}
    >
      <div :for={image <- @images} class="overflow-hidden rounded-lg">
        <%!-- One `case` over `RemoteImage.display_state/1` rather than a chain
        of `if`s, because the ORDER is the thing that was wrong (issue #1803):
        "is it still being checked" answers yes for a picture that was refused
        three weeks ago, so it may only be asked once "is it coming at all" has
        said yes. That order lives beside the columns it reads, not here. --%>
        <%= case RemoteImage.display_state(image) do %>
          <% :unavailable -> %>
            <%!-- The picture is not coming: the AI gate refused it, or its bytes
            never arrived and `Vutuv.Fediverse.MediaRefetcher` has stopped
            asking. It kept the waiting tile below until then, so a card promised
            a check that had finished weeks earlier — on some rows since
            2026-08-03. No hourglass and no explanation of *why*: one is a
            moderation decision that is not the reader's argument to have, the
            other is somebody else's server having a bad week, and from where the
            reader sits both are the same fact. The tile stays rather than
            vanishing, because a post from another network can be a photograph
            and nothing else, and a card with a silent hole in it reads as
            broken. --%>
            <div
              data-remote-image-unavailable
              class="flex min-h-24 items-center justify-center rounded-lg bg-slate-100 px-3 py-6 text-center text-xs text-slate-500 dark:bg-slate-800 dark:text-slate-400"
            >
              <span>{gettext("Picture unavailable")}</span>
            </div>
          <% :waiting -> %>
            <%!-- Recorded, not shown: still downloading from its own server, or
            still with the AI gate. Once the bytes are here the tile is the
            picture's own mosaic (issue #1720) with the badge on it; before that,
            and after the pixelated preview's window has run out, it is the
            wordless tile that keeps a photo post from rendering as an empty
            card. Both say the same thing, under the same hourglass, because it
            is the same wait: the picture is here and we are looking at it before
            showing it. The older "a picture is on its way" named the download
            instead, which is over in a second and is never what the reader is
            waiting for. --%>
            <% pixelated_url = RemoteMedia.post_image_pixelated_url(image) %>
            <div :if={pixelated_url} class="relative" data-remote-image-pixelated>
              <img
                src={pixelated_url}
                alt=""
                loading="lazy"
                class="block max-h-96 w-full rounded-lg object-cover"
              />
              <.checking_badge />
            </div>
            <div
              :if={!pixelated_url}
              data-remote-image-pending
              class="flex min-h-24 items-center justify-center gap-2 rounded-lg bg-slate-100 px-3 py-6 text-center text-xs text-slate-600 dark:bg-slate-800 dark:text-slate-400"
            >
              <.hourglass />
              <span>{gettext("Picture is being checked")}</span>
            </div>
          <% :sensitive -> %>
            <%!-- `<details>` rather than a JS toggle: the cover has to hold with
            no JavaScript at all, because "this is covered for a reason" is not a
            promise to break on a slow bundle. --%>
            <details data-remote-image-sensitive class="group relative">
              <%!-- The cover is inside the summary, so it must take itself away
              when the picture is shown: a `<summary>` renders open or closed
              alike, and without the `group-open:hidden` the blurred cover simply
              stayed on top of the picture it had just revealed. What stands in
              its place is the way back — like the content-warning lid above, a
              cover you cannot put back is not a cover. --%>
              <summary class="block cursor-pointer list-none">
                <span class="relative block group-open:hidden">
                  <img
                    src={RemoteMedia.post_image_url(image.id, image.file)}
                    alt=""
                    loading="lazy"
                    class="block max-h-96 w-full scale-105 object-cover blur-xl"
                  />
                  <span class="absolute inset-0 flex items-center justify-center p-3 text-center text-xs font-semibold text-white">
                    <span class="rounded-full bg-slate-900/70 px-3 py-2">
                      {gettext("Sensitive. Show the picture.")}
                    </span>
                  </span>
                </span>
                <span class="hidden min-h-10 items-center gap-1 text-xs font-medium text-brand-600 group-open:flex dark:text-brand-400">
                  <span aria-hidden="true">⚠</span>{gettext("Cover it again")}
                </span>
              </summary>
              <.remote_image image={image} />
            </details>
          <% :ready -> %>
            <.remote_image image={image} />
        <% end %>
      </div>
    </div>
    <%!-- The badge on a tile marks WHICH picture is waiting; this line says
    WHAT the wait is, and it is the half a reader actually reads. A member's
    own held photos have had it from the start (the placecard grid) — a
    fediverse card had only the corner pills, and two pixelated tiles under a
    post with no explanation read as a broken image rather than as a check in
    progress. Same words as the member's own, because it is the same wait. --%>
    <p
      :if={@held_count > 0}
      data-remote-images-checking={@held_count}
      class="mt-2 text-xs text-slate-600 dark:text-slate-400"
    >
      {ngettext(
        "Our AI is looking at it. It appears here by itself once it is through.",
        "Our AI is looking at them. They appear here by themselves once they are through.",
        @held_count
      )}
    </p>
    """
  end

  # Whether there is a body to render at all. A post from an account somebody
  # follows can be a photograph and nothing else (issue #1163) — the picture is
  # the post, so an empty body renders no rail and no empty paragraph, the same
  # as a local photo post.
  defp presence?(text), do: is_binary(text) and String.trim(text) != ""

  attr(:image, :map, required: true)

  # The picture itself — the same rendering whether it stood open or the reader
  # just uncovered a sensitive one, so it is written once.
  defp remote_image(assigns) do
    ~H"""
    <img
      src={RemoteMedia.post_image_url(@image.id, @image.file)}
      alt={@image.alt || ""}
      loading="lazy"
      class="block max-h-96 w-full object-contain"
    />
    """
  end

  @doc """
  A post by an account the reader follows on another network, in their feed
  (issue #1161).

  It wears the **same remote skin** as `remote_reply_card/1` — slate initials
  tile, globe badge, plain text — so "this did not come from vutuv" reads
  identically wherever it appears, and a member never has to learn two visual
  vocabularies for the same fact.

  What it has and what it deliberately does not:

    * **one action, not a bar.** A heart that really federates (issue #1164):
      it delivers a `Like` to the author and shows the reader's **own** state,
      with **no count**. vutuv does not know how many people liked a post on
      somebody else's server, and a number assembled from the likes that
      happened to pass through this installation would read as the real one
      while being a fraction of it. Replying and resharing are still their own
      issues (#1165, #1166); an absent control beats a dead one.
    * **a page for our copy, but not a published one.** The stamp in the header
      links to `/system/fediverse/post/:id` (`VutuvWeb.FediversePostLive`), the
      same place a member post's stamp leads — that is where the card came from
      when somebody links it to you, and where a photo-heavy post is readable
      without the feed around it. It is signed-in only and `noindex`, so the
      link is rendered only when there is a viewer.
    * **two ways out, no line of provenance.** The post itself still lives on
      its own server, and the header's **host chip is the link to it** — the
      pill already named the server, so being the way there costs no space at
      all; the ⋯ menu repeats it in words for a reader who does not try tapping
      a pill. The footer that used to say "From another network · host · View
      the original" under every card is gone with them (Stefan, 2026-08-01): it
      printed the globe badge, the chip and that link a second time, in the one
      spot on the card where a reader had to finish the post to reach it.

  A content warning (or the author's `sensitive` flag) renders as a closed lid
  and reveals the text on a click, which is the one thing that author asked for.
  """
  attr(:remote_post, :map, required: true, doc: "a Vutuv.Fediverse.RemotePost, account preloaded")
  attr(:viewer, :any, default: nil, doc: "the logged-in member, or nil")

  attr(:images, :list,
    default: [],
    doc: "the post's released pictures (issue #1163); the caller batches the read"
  )

  attr(:live?, :boolean,
    default: false,
    doc:
      "whether this surface is a LiveView that can host the action bar. False on a dead controller page, where a LiveComponent cannot render at all, and on the answering page, where the card is the read-only thing being answered."
  )

  attr(:marks, :any,
    default: nil,
    doc:
      "the viewer's like/repost/bookmark flags for this post when the host batched them; nil lets the bar load its own."
  )

  attr(:reposted_by, :any,
    default: nil,
    doc: "the member whose reshare put this card in the reader's feed, or nil"
  )

  attr(:boosted_by, :any,
    default: nil,
    doc: "the followed remote account whose boost put this card here (issue #1167), or nil"
  )

  attr(:following?, :boolean,
    default: true,
    doc:
      "whether the viewer follows this account, which is what the ⋯ menu's Mute and Unfollow both act on. Pass false where they are known not to (the lookup page, issue #1211, the tag timeline, a page's feed): acting on a follow that does not exist is a control that does nothing and a flash that says otherwise"
  )

  attr(:translations, :map,
    default: nil,
    doc: "the host's translation map (issue #1462), key {:remote_post, id} — see <.post_card>"
  )

  attr(:mode, :atom,
    default: :preview,
    values: [:preview, :full],
    doc:
      "`:preview` (every timeline: the feed, a profile, a tag page, the saved list) cuts the body to the reader's line budget like a member's post; `:full` renders it whole and is for the pages that ARE this one post"
  )

  def remote_post_card(assigns) do
    post = assigns.remote_post
    account = post.remote_account

    translation =
      card_translation(assigns, {:remote_post, post.id}, post.content_text, post.language)

    assigns =
      assigns
      |> assign(:translation, translation)
      |> assign(:body_id, "remote-post-body-#{post.id}")
      # The reader's own line budget, from the SAME `User.post_prefs/1` a
      # member's post reads: "how much of a post before I ask for more" is a
      # question about their screen, not about which server the post came from,
      # and a second knob for remote posts is one nobody would know to look for.
      |> assign(:body_style, post_body_style(User.post_prefs(assigns.viewer)))
      |> assign(:account, account)
      |> assign(:initials, name_initials(RemoteAccount.display_name(account) || account.handle))
      |> assign_remote_link_screenshot(post, assigns.images)
      |> assign(:permalink, remote_post_permalink(post, assigns.viewer))
      |> assign(:origin, RemotePost.origin(post))

    ~H"""
    <article data-remote-post={@remote_post.id} data-audience={@remote_post.audience}>
      <%!-- Why this card is in the reader's feed at all when they follow nobody
      out there (issue #1166): somebody here reshared it. The same line a local
      repost wears, so "X shared this" reads identically whichever world the
      post came from. --%>
      <.reshare_line
        :if={@reposted_by}
        name={full_name(@reposted_by)}
        href={~p"/#{@reposted_by}"}
        data-remote-reposted-by={@reposted_by.id}
      />

      <.boosted_banner :if={@boosted_by} account={@boosted_by} />

      <div class="flex items-start gap-3">
        <.remote_avatar initials={@initials} src={RemoteAccount.avatar_url(@account)} />

        <div class="min-w-0 flex-1">
          <%!-- The stamp is the author's own publication time, which is also
          what orders the feed: a post that reached us late must not read as
          newer than it is. --%>
          <.remote_header
            author={RemoteAccount.label(@account)}
            handle={RemoteAccount.display_handle(@account)}
            actor_uri={@account.actor_uri}
            at={@remote_post.published_at}
            network={@account.host}
            account_id={@account.id}
            permalink={@permalink}
            origin={@origin}
          >
            <:menu>
              <.card_menu :if={@viewer} id={"remote-post-menu-#{@remote_post.id}"}>
                <%!-- The way to the real thing, where a reader looks for what
                they can do with a post. The host chip in the header is the same
                link; a reader who has not learned that the pill is clickable
                finds it here, next to Mute and Report, the way the local card
                keeps its post actions. A poll says what the trip is for: a vote
                is not something vutuv can carry. --%>
                <:item
                  id={"remote-post-origin-#{@remote_post.id}"}
                  href={@origin}
                  target="_blank"
                  rel="nofollow noopener noreferrer"
                >
                  {origin_label(@remote_post)}
                </:item>
                <%!-- Mute first, and Report is not the only way out. The usual
                complaint about a followed account is "not today", and a report
                does not answer it: there is ONE cached row per post, shared by
                everybody who follows the author, so one member's report empties
                it out of all of their feeds. Muting is the private, reversible
                lever — the same one the member card's ⋯ menu offers — and the
                follow itself survives it. The handle rides the `hint` line
                rather than the label: `@user@host` is longer on its own than
                the menu is wide. --%>
                <:item
                  :if={@following?}
                  click="mute-remote-account"
                  value={@account.id}
                  hint={RemoteAccount.display_handle(@account)}
                >
                  {gettext("Mute")}
                </:item>
                <%!-- And the way out that lasts. Mute answers "not today";
                somebody who is done with an account had to go and find its page
                for that, from a card that offered them a report instead — so
                the follow can be taken back where it gets in the way. It asks
                first because it is not the reversible one: unfollowing drops
                the posts vutuv cached (`unfollow_remote/2`), so following again
                starts from an empty timeline. --%>
                <:item
                  :if={@following?}
                  click="unfollow-remote-account"
                  value={@account.id}
                  hint={RemoteAccount.display_handle(@account)}
                  confirm={
                    gettext("Stop following %{handle}? Their posts leave your feed.",
                      handle: RemoteAccount.display_handle(@account)
                    )
                  }
                >
                  {gettext("Unfollow")}
                </:item>
                <:item
                  click="report-remote-post"
                  value={@remote_post.id}
                  danger
                  confirm={
                    gettext(
                      "Report this post as not appropriate? Our copy is deleted for everyone on this vutuv right away."
                    )
                  }
                >
                  {gettext("Report")}
                </:item>
              </.card_menu>
            </:menu>
          </.remote_header>

          <%!-- A post its author addressed to their followers alone. The reader
          has to know it before they quote it anywhere. --%>
          <.remote_restricted_note :if={!RemotePost.open?(@remote_post)}>
            {gettext("Only for this account's followers")}
          </.remote_restricted_note>

          <%!-- The auto link screenshot floats beside the text exactly as on a
          member post's card, as the body's first child (a float only wraps what
          follows it); the body contains it, so a tall shot beside a short body
          cannot spill over the action bar below. A warned post never has one,
          so the float can never sit beside a closed lid. --%>
          <.remote_body
            warning={
              RemotePost.warned?(@remote_post) &&
                (translated_summary(@translation, @remote_post.summary) ||
                   gettext("Marked as sensitive by its author"))
            }
            text={@translation.body_source}
            lang={@translation.lang}
            mode={@mode}
            body_id={@body_id}
            body_style={@body_style}
          >
            <:float :if={@link_screenshot}>
              <.link_screenshot_image
                screenshot={@link_screenshot}
                pixelated_url={@screenshot_pixelated}
                class="float-right mb-1 ml-4 mt-1.5 w-2/5 sm:w-1/3"
              />
            </:float>
          </.remote_body>

          <.translation_line
            state={@translation.state}
            offer?={@translation.offer?}
            kind="remote_post"
            subject_id={@remote_post.id}
          />

          <.remote_post_images images={@images} />

          <%!-- The same bar, from the same component (issues #1164, #1165,
          #1166 and #1276) — a reply and a cached post are the same kind of
          thing to a reader, so "what can I do with this" has one definition. --%>
          <.live_component
            :if={@live? and @viewer}
            module={RemoteActionsComponent}
            id={RemoteActionsComponent.dom_id(@remote_post)}
            subject={@remote_post}
            viewer={@viewer}
            marks={@marks}
          />
        </div>
      </div>
    </article>
    """
  end

  defp origin_label(post) do
    if RemotePost.question?(post),
      do: gettext("Vote on the original"),
      else: gettext("View the original")
  end

  # Our copy's own page (`VutuvWeb.FediversePostLive`), for the stamp in the
  # header. Signed-in readers only, because that page is: it is assembled from
  # what somebody else wrote on somebody else's server, so it is a members' page
  # like every other `/system/fediverse/*` one — and a link an anonymous reader
  # of the tag timeline could only follow into a login wall is worse than the
  # plain stamp they have today.
  defp remote_post_permalink(%RemotePost{id: id}, %User{}),
    do: ~p"/system/fediverse/post/#{id}"

  defp remote_post_permalink(_post, _viewer), do: nil

  @doc """
  The sentence for one `{:error, reason}` refusing the heart above (issue
  #1164). Beside the control rather than in each of the two pages that render
  it (`/feed` and the account page), so the same refusal cannot be explained
  precisely on one and shrugged at on the other.

  Its own table and not `VutuvWeb.FediverseComponents.refusal_message/1`, which
  answers the *follow* pages: the one refusal a member can act on says what to
  do about it, and the rest deliberately say only that it did not work. Somebody
  who pressed a heart while reading has not asked to be told what the operator
  blocks, and that table's fallback tells them to check an address a like does
  not have.

  `subject` names what was pressed — a cached post (the default) or a reply from
  another network (issue #1270). It changes exactly one sentence, the one that
  says the thing is gone; everything else is about the member's own standing and
  reads the same whichever it was. One table with a subject beats two tables
  that drift.
  """
  def like_refusal_message(reason, subject \\ :post)

  def like_refusal_message(:like_capped, _subject),
    do: gettext("That is a lot of likes in one hour. Please try again later.")

  def like_refusal_message(reason, :reply) when reason in [:not_found, :not_visible],
    do: gettext("That reply is not here any more.")

  def like_refusal_message(reason, _subject) when reason in [:not_found, :not_visible],
    do: gettext("That post is not here any more.")

  # The one refusal a member can act on, and the one this table stopped
  # borrowing from `FediverseComponents.refusal_message/1` (issue #1349). That
  # sentence answers the *follow* pages: "there is no identity to sign the
  # request with" is true of a follow request and reads, after a heart on a post
  # somebody is reading, as vutuv not knowing who pressed it — the member who
  # reported it logged out and back in twice before writing the issue, and
  # titled it "User is not recognized". Practically every reader meets this, not
  # a rare few: taking part in the Fediverse is opt-in and most members have not
  # opted in, while remote posts reach their feed anyway through the people they
  # follow here. So it says what the act would have done and leaves the way to
  # the setting to the bar, which renders it as a real link beside this.
  #
  # What it deliberately does not say is "your switch is off": `federated?/1` is
  # false for an unconfirmed address, a frozen or a suspended account too, whose
  # switch is already on. The settings page tells them which it is.
  #
  # NOTE the `{settings}` marker: this is the one sentence in this table that
  # names a page, and naming one without linking it is what left the reporter
  # with nothing to try but logging out and back in. The bar splits the
  # translation there (`UI.split_marker/2` — never a hard pattern match on a
  # translated string) and puts the link in its place. A caller that renders
  # this table's answers as plain text must swap the marker for
  # `gettext("Fediverse settings")` itself.
  def like_refusal_message(:not_federating, _subject),
    do:
      gettext(
        "A like or a repost is sent back to the network this post came from, and your account does not take part in the Fediverse at the moment. You can switch it on in the {settings}."
      )

  # The other states a member is in rather than a fact about this act: those
  # already have one wording in `FediverseComponents.refusal_message/1`. Only
  # its catch-all is overridden, which is about an address a heart does not have.
  def like_refusal_message(reason, _subject)
      when reason in [:moved, :fediverse_disabled, :instance_blocked],
      do: FediverseComponents.refusal_message(reason)

  def like_refusal_message(_reason, _subject), do: gettext("That did not work.")

  @doc """
  The chrome both "answer something on another network" pages wear: the reply
  that arrived under one of the member's own posts
  (`VutuvWeb.PostLive.RemoteReply`, issue #1070) and the post by an account they
  follow (`VutuvWeb.PostLive.RemotePostReply`, issue #1165).

  One definition, because what the two pages share is exactly what must never
  drift between them: the sentence saying **before anybody types** that these
  words leave the site, and the explanation a member who has not switched
  Fediverse participation on gets instead of a hidden action. Each page still
  brings what is genuinely its own — the card for the thing being answered, the
  composer with its own context (and so its own save path), the way back, and
  the one sentence that names what kind of thing is being answered.
  """
  attr(:id, :string, required: true, doc: "the page wrapper's id")
  attr(:handle, :string, required: true, doc: "`@user@host` of the person being answered")

  attr(:refusal, :atom,
    default: nil,
    doc:
      "`:not_federating` puts the explanation where the composer would be; every other refusal redirects before this renders"
  )

  attr(:explanation, :string,
    required: true,
    doc: "why the words would leave the site, in the terms of this page's target"
  )

  attr(:back_href, :any, default: nil, doc: "the way back, or nil for no link")
  attr(:back_label, :string, default: nil)

  slot(:target, required: true, doc: "the remote card showing what is being answered")
  slot(:composer, required: true)

  def remote_answer_page(assigns) do
    ~H"""
    <div id={@id} class="py-6">
      <div class="mx-auto max-w-2xl space-y-4">
        <h1 class="text-2xl font-bold text-slate-800 dark:text-slate-100">
          {gettext("Reply to %{handle}", handle: @handle)}
        </h1>

        <.card>{render_slot(@target)}</.card>

        <%= if @refusal == :not_federating do %>
          <.card>
            <h2 class="mb-2 text-base font-semibold text-slate-900 dark:text-white">
              {gettext("Turn on Fediverse participation to answer")}
            </h2>
            <p class="mb-3 text-sm text-slate-600 dark:text-slate-400">{@explanation}</p>
            <.button navigate={~p"/settings/fediverse"}>
              {gettext("Open Fediverse settings")}
            </.button>
          </.card>
        <% else %>
          <%!-- Said before they type, not after they send: the whole point of
          the page is that nobody publishes to another network by accident. --%>
          <p
            data-remote-reply-notice
            class="rounded-lg bg-brand-50 px-4 py-3 text-sm text-brand-800 dark:bg-brand-900/30 dark:text-brand-100"
          >
            {gettext(
              "Your answer goes to %{handle} on their own server and to your Fediverse followers. It is a public post on vutuv as well.",
              handle: @handle
            )}
          </p>

          {render_slot(@composer)}
        <% end %>

        <.link
          :if={@back_href}
          href={@back_href}
          class="text-sm font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
        >
          {@back_label}
        </.link>
      </div>
    </div>
    """
  end

  @doc """
  The sentence for one `{:error, reason}` that keeps a member off those pages
  entirely (`Vutuv.Fediverse.check_remote_reply/2` and
  `check_remote_post_reply/2` answer in one vocabulary, so one table covers
  both). `:not_federating` is deliberately absent: it is the one refusal the
  member can act on, so it gets the page and its explanation rather than a
  sentence on the way out.

  Its own table and not `like_refusal_message/1` beside it: a member who opened
  a page in order to write something has asked why they cannot, where somebody
  who pressed a heart while reading has not.
  """
  def answer_refusal_message(:note_not_public),
    do: gettext("This reply was sent to you alone, so it cannot be answered publicly.")

  def answer_refusal_message(:post_not_public),
    do:
      gettext(
        "This post was published to that account's followers only, so it cannot be answered with a public post here."
      )

  def answer_refusal_message(:instance_blocked),
    do: gettext("That server is blocked on this site, so no answer can be sent to it.")

  def answer_refusal_message(:moved),
    do:
      gettext(
        "You moved your Fediverse account to another server, so answers are no longer sent from here."
      )

  def answer_refusal_message(_disabled),
    do: gettext("This site does not take part in the Fediverse.")

  # A card names the post it answers only when its position alone does not say
  # it. While the thread still indents, the nesting says it. Past
  # @thread_indent_cap it says nothing at all: every card shares its parent's
  # column, so a whole run of generations reads as one flat list of siblings —
  # which is how issue #1156 came in, its reporter unable to find the post his
  # permalink answered though it sat two cards above. So every card past the
  # cap names its parent, first answer included: the exemption used to argue
  # that the first one is rendered directly below the post it answers, but with
  # several capped generations stacked the card above is just as likely to be
  # its own grandparent or a cousin. A forest root keeps it either way: its
  # parent is off the page.
  defp reply_banner?(node, connected?, indent?) do
    Map.get(node, :show_reply_banner, false) or (connected? and not indent?)
  end

  # Each node paired with whether it is the first and the last of its siblings —
  # what the connector geometry above branches on.
  defp mark_last(nodes) do
    last = length(nodes) - 1
    Enum.with_index(nodes, fn node, i -> {node, i == 0, i == last} end)
  end

  @doc """
  The permalink page's whole-conversation rendering (issue #1006): every post
  of `posts` (the thread in reading order, `Vutuv.Posts.list_thread/3`) as one
  connected conversation — the same look as a feed thread row. The permalinked
  `focus_id` post renders in `:full` mode, tinted as the page's subject and,
  when it has context above it, marked for the arrival auto-scroll
  (`data-thread-scroll`, wired in app.js). Every reply hangs under the post it
  actually answers (`Vutuv.Posts.thread_forest/1`), so only a card whose parent
  is off the page keeps its own "Replying to @handle" banner.
  """
  attr(:posts, :list, required: true, doc: "the whole conversation, in reading order")
  attr(:focus_id, :string, required: true, doc: "the permalinked post's id")
  attr(:viewer, :any, default: nil)

  attr(:auto_scroll?, :boolean,
    default: true,
    doc:
      "false suppresses the arrival scroll jump: the headless page capture " <>
        "screenshots from the document top, so a page that scrolls itself is " <>
        "shot before those tiles are painted and comes out blank (issue #1033)"
  )

  attr(:viewer_follows, :map,
    default: %{},
    doc:
      "the viewer's follow edges by author id (Vutuv.Social.follow_edges/2), " <>
        "batched for the cards' mute menu items like the feed does"
  )

  attr(:engagement, :map,
    default: %{},
    doc:
      "action-bar engagement by post id (Vutuv.Posts.post_engagement_map/2), " <>
        "batched by the host so the cards' bars don't each load their own"
  )

  attr(:remote_replies, :map,
    default: %{},
    doc:
      "replies from other networks by the post id they answer " <>
        "(Vutuv.Fediverse.list_notes/2, already viewer-scoped): woven in as " <>
        "siblings of that post's own answers, in time order"
  )

  attr(:note_marks, :any,
    default: nil,
    doc:
      "a fun from a note to its `%{liked?:, reposted?:, bookmarked?:}` map, " <>
        "batched by the host so the remote reply cards' bars don't each ask " <>
        "for themselves (`Vutuv.Fediverse.liked_ids/2` and friends)"
  )

  attr(:likers, :any,
    default: nil,
    doc:
      "the permalinked post's \"Liked by\" row (issue #1233); it rides that " <>
        "one card, never the replies around it"
  )

  attr(:conn_or_socket, :any, required: true)
  attr(:translations, :map, default: nil)

  def thread_conversation(assigns) do
    top_id = with %{id: id} <- List.first(assigns.posts), do: id
    assigns = assign(assigns, :roots, conversation_nodes(assigns.posts, top_id, assigns))

    ~H"""
    <.thread_chain
      nodes={@roots}
      viewer={@viewer}
      surface={:flat}
      conn_or_socket={@conn_or_socket}
      translations={@translations}
    />
    """
  end

  @doc """
  A **windowed** conversation on the permalink page (`VutuvWeb.PostLive.Thread`):
  the rendering of `Vutuv.Posts.thread_window/3`'s `:window` mode. The root
  stays pinned on top; when ancestors between it and the shown chain are
  elided, a "Show N earlier posts" expander stands in for them (so the chain
  below it starts as its own forest, its top card keeping the reply banner
  that names the elided parent); below the permalinked post's subtree chunk a
  "Show N more replies" expander loads the next chunk. Both fire plain
  `phx-click` events handled by the hosting LiveView — no custom JS.
  """
  attr(:window, :map, required: true, doc: "Vutuv.Posts.thread_window/3 result, mode :window")
  attr(:focus_id, :string, required: true)
  attr(:viewer, :any, default: nil)
  attr(:auto_scroll?, :boolean, default: true)
  attr(:viewer_follows, :map, default: %{})
  attr(:engagement, :map, default: %{})
  attr(:remote_replies, :map, default: %{})
  attr(:note_marks, :any, default: nil)
  attr(:likers, :any, default: nil)
  attr(:conn_or_socket, :any, required: true)
  attr(:translations, :map, default: nil)

  def thread_window_conversation(assigns) do
    window = assigns.window
    top_id = with %{id: id} <- window.root || List.first(window.subtree), do: id

    # With elided ancestors the pinned root and the window are separate
    # forests (the expander stands between them); otherwise the chain connects
    # the root and everything renders as one tree.
    {root_nodes, window_posts} =
      if window.gap > 0 do
        {conversation_nodes([window.root], top_id, assigns), window.chain ++ window.subtree}
      else
        {nil, List.wrap(window.root) ++ window.chain ++ window.subtree}
      end

    assigns =
      assigns
      |> assign(:root_nodes, root_nodes)
      |> assign(:window_nodes, conversation_nodes(window_posts, top_id, assigns))

    ~H"""
    <%= if @root_nodes do %>
      <.thread_chain
        nodes={@root_nodes}
        viewer={@viewer}
        surface={:flat}
        conn_or_socket={@conn_or_socket}
        translations={@translations}
      />
      <div class="py-3 pl-1">
        <button
          id="thread-earlier"
          type="button"
          phx-click="thread-earlier"
          class="text-sm font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
        >
          {ngettext(
            "Show %{formatted} earlier post",
            "Show %{formatted} earlier posts",
            @window.gap,
            formatted: compact_count(@window.gap)
          )}
        </button>
      </div>
    <% end %>
    <.thread_chain
      nodes={@window_nodes}
      viewer={@viewer}
      surface={:flat}
      conn_or_socket={@conn_or_socket}
      translations={@translations}
    />
    <div :if={@window.more > 0} class="pl-1 pt-3">
      <button
        id="thread-more"
        type="button"
        phx-click="thread-more"
        class="text-sm font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
      >
        {ngettext(
          "Show %{formatted} more reply",
          "Show %{formatted} more replies",
          @window.more,
          formatted: compact_count(@window.more)
        )}
      </button>
    </div>
    """
  end

  # The plain preloaded `posts` as `thread_chain/1` nodes: the permalinked
  # `focus_id` post in `:full` mode (tinted, and — with context above it —
  # marked for the arrival auto-scroll), everything else a preview. `top_id`
  # is the first card on the page, the one case where the focused post has no
  # context above it and the page must not jump on arrival.
  defp conversation_nodes(posts, top_id, assigns) do
    posts
    |> Enum.map(fn post ->
      focus? = post.id == assigns.focus_id

      %{
        post: post,
        engagement: assigns.engagement[post.id],
        viewer_follow: assigns.viewer_follows[post.user_id],
        reposted_by: nil,
        reposters: nil,
        entry_id: nil,
        mode: if(focus?, do: :full, else: :preview),
        # The "Liked by" row rides the permalinked post alone (issue #1233):
        # every other card in the conversation is an ordinary preview. `if`,
        # not `&&` — a false would reach the card as a truthy-looking assign.
        likers: if(focus?, do: assigns[:likers]),
        focus?: focus?,
        scroll?: assigns.auto_scroll? and focus? and post.id != top_id
      }
    end)
    |> Posts.thread_forest()
    |> banner_on_roots()
    |> weave_remote_replies(
      assigns[:remote_replies] || %{},
      assigns.viewer,
      assigns[:note_marks] || fn _note -> nil end
    )
  end

  # Hangs the replies written on other networks (issue #1069) under the posts
  # they answer, merged into that post's own answers **in time order** rather
  # than parked in a block below them. They are part of the conversation, so
  # they read as part of it; what marks them out is the card, not a ghetto.
  #
  # `remote_replies` is `Vutuv.Fediverse.list_notes/2`'s per-post map, already
  # viewer-scoped — a reply addressed to the member alone never reaches anybody
  # else's render.
  defp weave_remote_replies(nodes, remote, _viewer, _marks) when remote == %{}, do: nodes

  defp weave_remote_replies(nodes, remote, viewer, marks) do
    Enum.map(nodes, fn node ->
      children =
        node.children
        |> weave_remote_replies(remote, viewer, marks)
        |> merge_remote_nodes(Map.get(remote, node.post.id, []), node.post, viewer, marks)

      %{node | children: children}
    end)
  end

  defp merge_remote_nodes(children, [], _post, _viewer, _marks), do: children

  defp merge_remote_nodes(children, notes, post, viewer, marks) do
    # Who gets the "Remove" item — `Posts.author?/2`, the same predicate that
    # gates Edit and Delete, so a page's publishers get it too. Comparing
    # `post.user_id` here left an organization post's team with only "Report",
    # which deletes the reply AND files an accusation with the origin server:
    # there was no way to quietly take something off your own page.
    owner? = match?(%User{}, viewer) and Posts.author?(post, viewer)

    # An answer to one of these notes (issue #1070) is, underneath, an ordinary
    # reply to the same vutuv post — so `thread_forest/1` made it a *sibling* of
    # the note it answers. Move it under the note, which is where the reader
    # expects it and what the note's own server shows too.
    {answers, siblings} = Enum.split_with(children, &(answered_note_id(&1) in note_ids(notes)))

    remote_nodes =
      Enum.map(notes, fn note ->
        %{
          note: note,
          owner?: owner?,
          marks: marks.(note),
          children:
            answers
            |> Enum.filter(&(answered_note_id(&1) == note.id))
            |> Enum.sort_by(&node_time/1, {:asc, NaiveDateTime})
        }
      end)

    Enum.sort_by(siblings ++ remote_nodes, &node_time/1, {:asc, NaiveDateTime})
  end

  defp note_ids(notes), do: Enum.map(notes, & &1.id)

  # Which remote reply this node answers, or nil for every ordinary post. An
  # un-preloaded association is a truthy `NotLoaded`, so it is matched away
  # rather than treated as an answer.
  defp answered_note_id(%{post: %{remote_reply_ref: %PostRemoteReply{note_id: note_id}}}),
    do: note_id

  defp answered_note_id(_node), do: nil

  defp node_time(%{note: note}), do: DateTime.to_naive(note.received_at)
  defp node_time(%{post: post}), do: post.inserted_at

  # Fallback when a caller does not compute the full visible chain: the single
  # preloaded `reply_ref` parent (one level), or none when nesting is off (the
  # permalink, where the parent is the page) or the post is not a reply.
  defp one_level_ancestors(_post, false), do: []

  defp one_level_ancestors(post, true) do
    case Posts.reply_ref_state(post) do
      {:parent, parent} -> [parent]
      _ -> []
    end
  end

  attr(:variant, :string, required: true)
  slot(:inner_block, required: true)

  defp reply_banner_line(assigns) do
    ~H"""
    <p
      class="mb-3 flex items-center gap-1.5 text-xs font-semibold text-slate-600 dark:text-slate-400"
      data-reply-banner={@variant}
    >
      <.icon_reply class="h-4 w-4" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  defp render_post_card_inner(assigns) do
    ~H"""
    <%!-- data-quote-reply names this card's Reply control, so a text selection
    inside its body can ride along to the reply page as a quote (issue #1114,
    wired in app.js). It sits on the card, not on the body, because thread cards
    nest: the INNERMOST marked ancestor of the selection is the post that was
    marked. Absent on a restricted post, whose Reply control is a dead span. --%>
    <div data-quote-reply={@quotable and not @restricted? and "#{@actions_id}-reply"}>
      <%!-- The owner's freezer notice: only the author (and admins) still see
      a reported post; everyone else gets nothing, not even a tombstone. --%>
      <.frozen_banner :if={@frozen? and @author?} class="mb-3 rounded-lg px-3 py-2 text-xs">
        {gettext("Only you can see this post while a report about it is handled.")}
      </.frozen_banner>

      <%!-- The pinned marker (issue #1110): brand-tinted, not the muted grey of
      the repost/reply lines, because "this one is pinned" is the card's whole
      reason for sitting above the timeline. --%>
      <p
        :if={@show_pin_banner?}
        class="mb-3 flex items-center gap-1.5 text-xs font-semibold text-brand-700 dark:text-brand-300"
        data-pinned-banner
      >
        <.icon_pin class="h-4 w-4 shrink-0" />
        {gettext("Pinned post")}
      </p>

      <.reposted_banner reposters={@reposters} reposters_total={@reposters_total} />

      <%!-- The reply banner: the live parent links its permalink; a deleted
      parent degrades to the author's profile, a deleted account to a
      nameless notice (no name retained past account deletion). --%>
      <%= case @reply_banner do %>
        <% {:parent, parent_author, parent_path} -> %>
          <.reply_banner_line variant="parent">
            <.link href={parent_path} class="hover:text-brand-700 dark:hover:text-brand-300">
              {gettext("Replying to %{handle}", handle: author_handle(parent_author))}
            </.link>
          </.reply_banner_line>
        <% {:author_only, parent_author} -> %>
          <.reply_banner_line variant="author-only">
            <%!-- `Posts.author_path/1` takes the author directly, so the page a
            page-published parent belonged to is reached the same way a member's
            profile is. --%>
            <.link href={Posts.author_path(parent_author)} class="hover:text-brand-700 dark:hover:text-brand-300">
              {gettext("Reply to a now-deleted post by %{handle}",
                handle: author_handle(parent_author)
              )}
            </.link>
          </.reply_banner_line>
        <% {:remote, remote_handle, remote_account_id} -> %>
          <%!-- Answering a post on another network (issue #1165). The link goes
          to that account's page *here* rather than out to their server: the
          reader is one click from the same context the answer's author had,
          without leaving the site and without an outbound request. It degrades
          to plain text once our copy of the post has expired, since the account
          is reached through the post. --%>
          <.reply_banner_line variant="remote">
            <.link
              :if={remote_account_id}
              navigate={~p"/system/fediverse/account/#{remote_account_id}"}
              class="hover:text-brand-700 dark:hover:text-brand-300"
            >
              {gettext("Replying to %{handle}", handle: remote_handle)}
            </.link>
            <span :if={!remote_account_id}>
              {gettext("Replying to %{handle}", handle: remote_handle)}
            </span>
          </.reply_banner_line>
        <% :gone -> %>
          <.reply_banner_line variant="gone">
            {gettext("Reply to a deleted post")}
          </.reply_banner_line>
        <% nil -> %>
      <% end %>

      <div class="flex items-start gap-3">
        <%!-- Decorative duplicate of the author-name link below; hidden from
        assistive tech and the tab order so the name link is the one profile
        link (otherwise the avatar link has no accessible name). --%>
        <.link href={@author_path} class="shrink-0" aria-hidden="true" tabindex="-1">
          <%!-- An organization wears its logo, not an avatar: it has no
          presence dot to carry either, since nobody is ever "online" as a
          page. --%>
          <.organization_logo :if={@organization_author?} organization={@author} class="h-10 w-10" />
          <.avatar :if={!@organization_author?} user={@post.user} size="sm" presence />
        </.link>

        <div class="min-w-0 flex-1">
          <%!-- The ⋯ menu rides this header row (right-aligned via the name
          block's flex-1) so the body below spans the full content column. When
          the menu was a sibling of that column it narrowed it for its whole
          height, and the body text wrapped early at the menu's left edge. --%>
          <div class="flex items-start gap-2">
            <div class="flex min-w-0 flex-1 flex-wrap items-baseline gap-x-2">
              <.link
                href={@author_path}
                class="font-semibold text-slate-900 hover:text-brand-700 dark:hover:text-brand-300 dark:text-white"
              >
                {@author_name}
              </.link>
              <.link href={@permalink} class="text-sm text-slate-600 dark:text-slate-400 hover:text-brand-700 dark:hover:text-brand-300">
                <.post_time id={@time_id} at={@post.inserted_at} />
              </.link>
              <span :if={@edited?} class="text-xs text-slate-600 dark:text-slate-400">{gettext("edited")}</span>
              <span
                :if={@restricted?}
                title={gettext("Limited audience")}
                class="text-xs text-slate-600 dark:text-slate-400"
                aria-label={gettext("Limited audience")}
              >
                🔒
              </span>
            </div>

            <%!-- The author's quiet ⋯ menu, on every rendering of their post.
            Edit drops out once the edit window closed (issue #1023); the
            engagement half of that gate needs a query, so a post liked inside
            the window still shows the item and the edit page explains. --%>
            <div :if={@author?} class="-mr-1 -mt-1 shrink-0">
              <.card_menu id={@menu_id}>
                <:item :if={@editable?} href={~p"/posts/#{@post.id}/edit"}>{gettext("Edit")}</:item>
                <%!-- The profile pin (issue #1110). Only one post can be pinned,
                so pinning while another post holds the spot asks first and says
                what it replaces — the rule is visible where it bites, not buried
                in a help text. --%>
                <:item
                  :if={!@organization_author? and !@pinned_to_profile?}
                  id={@pin_item_id}
                  href={~p"/posts/#{@post.id}/pin"}
                  method="put"
                  confirm={
                    if(@pin_replaces_other?,
                      do:
                        gettext(
                          "Only one post can be pinned to your profile. Pin this one and release the other?"
                        )
                    )
                  }
                >
                  {gettext("Pin to profile")}
                </:item>
                <:item
                  :if={!@organization_author? and @pinned_to_profile?}
                  id={@unpin_item_id}
                  href={~p"/posts/#{@post.id}/pin"}
                  method="delete"
                >
                  {gettext("Unpin from profile")}
                </:item>
                <:item
                  href={~p"/posts/#{@post.id}"}
                  method="delete"
                  confirm={gettext("Delete this post permanently?")}
                  danger
                >
                  {gettext("Delete")}
                </:item>
              </.card_menu>
            </div>

            <%!-- Everyone else gets the same quiet ⋯ menu with the Report action,
            plus a Mute toggle when the viewer follows this author, so an annoying
            post can be silenced straight from the feed. Mute keeps the follow (and
            any vernetzt status); it only drops the author's posts from your feed. --%>
            <div :if={@reporter?} class="-mr-1 -mt-1 shrink-0">
              <.card_menu id={@report_menu_id}>
                <:item
                  :if={@viewer_follow && !@organization_author?}
                  href={~p"/follows/#{@viewer_follow.id}/mute"}
                  method="put"
                  hint={"@" <> @post.user.username}
                >
                  {if @viewer_follow.muted?, do: gettext("Unmute"), else: gettext("Mute")}
                </:item>
                <:item href={~p"/reports/new?#{[type: "post", id: @post.id, return_to: @permalink]}"}>
                  {gettext("Report")}
                </:item>
              </.card_menu>
            </div>
          </div>

          <%!-- Prose + review card. A review post lays the two out side by
          side from `md` up — the prose keeps the column, the card becomes a
          narrow right-hand aside, the way a book page prints its metadata
          beside the text. `md` (not `lg`) so portrait tablets and small
          laptop windows get the side-by-side reading too, not just wide
          desktops. Below `md` (and for every post without a review) this is
          one plain column and the card sits under the prose as before: the
          card is the row's SECOND child, so the stacked order never changes
          and no markup is duplicated per breakpoint. The images/gallery ride
          in the prose column too, so a photo lands beside the card rather
          than under it in a half-empty row. --%>
          <div class={@review_aside? && "md:flex md:items-start md:gap-4"}>
            <div class={@review_aside? && "min-w-0 md:flex-1"}>
              <%!-- Full mode: the whole body, no clamp. The reader's hyphenation
              preference still rides along via @body_style (the clamp vars in it are
              simply unused here). The tags live INSIDE the body flow so they follow
              the end of the text — beside a tall floated inline image (a flex row
              establishes its own formatting context, so the float narrows it
              instead of overlapping) rather than pushed below the whole picture;
              the container's clearfix (`.markdown--post::after`) keeps everything
              after this div below the float. The link screenshot floats here too,
              ahead of the prose (a float only wraps what follows it) — the same
              beside-the-text reading as the preview, at the same width. --%>
              <div
                :if={@mode == :full and @post.body != ""}
                data-post-body
                lang={@translation.lang}
                class="markdown markdown--post mt-2 text-slate-800 dark:text-slate-200"
                {style_attrs(@body_style)}
              >
                <.link_screenshot_image
                  :if={@link_screenshot}
                  screenshot={@link_screenshot}
                  pixelated_url={@screenshot_pixelated}
                  class="float-right mb-1 ml-4 w-2/5 sm:w-1/3"
                />
                {@body_html}
                <.post_tags tags={@post.tags} />
              </div>

              <%= cond do %>
            <% @square_layout? -> %>
              <%!-- A single roughly-square image (see @square_ratio_*) FLOATS to
              the top-right and the body text wraps around it and reclaims the full
              width below it — no dead column of whitespace beside a short image.
              At ~1/3 of the column a squarish image renders whole (no crop). See
              the `.post-clamp--wrap` note in components.css for how the height
              clamp respects the float. --%>
              <.preview_body
                body_id={@body_id}
                body_html={@body_html}
                body_style={@body_style}
                class="mt-2 text-slate-800 dark:text-slate-200"
                tags={@post.tags}
                lang={@translation.lang}
                wrap
              >
                <:float>
                  <.link
                    href={@permalink}
                    aria-label={gettext("View post")}
                    class="float-right mb-1 ml-4 w-2/5 sm:w-1/3"
                  >
                    <img
                      src={PostImage.url(hd(@gallery), "feed")}
                      alt={hd(@gallery).alt}
                      width={hd(@gallery).width}
                      height={hd(@gallery).height}
                      loading="lazy"
                      class="w-full rounded-lg ring-1 ring-slate-200 dark:ring-slate-800"
                    />
                  </.link>
                </:float>
              </.preview_body>
            <% @link_screenshot_layout? -> %>
              <%!-- A single-URL, image-less post: the link-page screenshot floats
              to the top-right and the body wraps around it, same as the square
              image above. --%>
              <.preview_body
                body_id={@body_id}
                body_html={@body_html}
                body_style={@body_style}
                class="mt-2 text-slate-800 dark:text-slate-200"
                tags={@post.tags}
                lang={@translation.lang}
                wrap
              >
                <:float>
                  <.link_screenshot_image
                    screenshot={@link_screenshot}
                    pixelated_url={@screenshot_pixelated}
                    class="float-right mb-1 ml-4 w-2/5 sm:w-1/3"
                  />
                </:float>
              </.preview_body>
            <% @mode == :preview -> %>
              <.preview_body
                :if={@post.body != ""}
                body_id={@body_id}
                body_html={@body_html}
                body_style={@body_style}
                class="mt-2 text-slate-800 dark:text-slate-200"
                media={@inline_media?}
                tags={@post.tags}
                lang={@translation.lang}
              />

              <%!-- Attachments the body does NOT reference inline. A single
              photo shows **whole** (a squarish one floats above; every other
              ordinary shape renders uncropped below) — see
              `<.single_feed_photo>`. Multiple images tile through the shared
              `post_gallery` as the bento mosaic. --%>
              <.link
                :if={length(@gallery) == 1}
                href={@permalink}
                aria-label={gettext("View post")}
                class="mt-3 block"
              >
                <.single_feed_photo image={hd(@gallery)} />
              </.link>
              <.post_gallery
                :if={length(@gallery) > 1}
                gallery={@gallery}
                mode={:preview}
                permalink={@permalink}
                license={@post.license}
                layout={@post.gallery_layout}
                fill={@post.gallery_fill?}
              />
            <% true -> %>
              <.post_gallery
                :if={@gallery != []}
                gallery={@gallery}
                mode={:full}
                permalink={@permalink}
                license={@post.license}
              />
              <%!-- The rights line, under the photos where somebody deciding
              whether they may use one is looking. Shown only on a post that
              has photos and only when the author granted something: "all
              rights reserved" is the default nobody chose, and a line saying
              so on every picture in the app would be noise. --%>
              <.photo_license_line :if={@gallery != []} license={@post.license} />
              <% end %>
            </div>

            <%!-- The book/film review card (the post's structured sidecar,
            Vutuv.Posts.PostReview): cover or kind glyph, title, creator, year
            and the shop/IMDb link. Rendered in both modes, outside the clamp,
            so the reviewed work is always visible with the prose. --%>
            <.review_card
              :if={@review}
              review={@review}
              author?={@author?}
              aside={@review_aside?}
            />
          </div>

          <%!-- AI-moderation limbo. The post itself is published from the
          moment it is written; only the picture waits. For every viewer but
          the author/admin a pending photo therefore renders as its own mosaic
          (issue #1720) — or, once the wait has run past the pixelated preview's window,
          as the grey tile that came before it. Either way the line under the
          grid says the rest: the check is running, and the photo turns up here
          by itself. The author instead sees the image (filtered in above) plus
          the amber progress panel below. --%>
          <div :if={@held_images != []} class="mt-3" data-image-placecards>
            <div class={["grid gap-2", length(@held_images) > 1 && "grid-cols-2"]}>
              <.held_photo :for={image <- @held_images} image={image} />
            </div>
            <%!-- The sentence sits under the grid and not inside every tile:
            six tiles repeating one paragraph is noise, and in the two-column
            grid a tile is ~150px wide on a phone, where the German would run
            past its own 4:3 box. --%>
            <p class="mt-2 text-xs text-slate-600 dark:text-slate-400">
              {ngettext(
                "Our AI is looking at it. It appears here by itself once it is through.",
                "Our AI is looking at them. They appear here by themselves once they are through.",
                length(@held_images)
              )}
            </p>
          </div>

          <%!-- The author's own progress line while the AI scan runs. It is
          deliberately louder than the old static pill: the check takes real
          time on a multi-photo post, and a card that simply sits there with no
          moving part reads as broken rather than as busy. So the hourglass
          animates, the line counts the photos off as they clear, and the whole
          thing disappears by itself when the last one lands (the host
          LiveViews refresh the card on `{:post_images_settled, …}`) — no
          reload, and nothing to click. --%>
          <.photo_check_progress :if={@limbo_pill?} progress={@check_progress} />


          <%!-- The remaining layouts put the tags in their own full-width row
          below the body/images: plain (line-clamp) previews — no float there,
          so this row already sits at the end of the text — and the photo-only
          renderings (no body to end). Everything float-capable carries the
          tags at the end of the text instead: full mode inside the body div,
          the wrap/media previews inside `<.preview_body>`. --%>
          <.post_tags
            :if={
              not @square_layout? and not @link_screenshot_layout? and
                not (@mode == :full and @post.body != "") and
                not (@mode == :preview and @inline_media?)
            }
            tags={@post.tags}
          />

          <.liked_by :if={@likers} likers={@likers} />

          <%!-- The translation line (issue #1462): the quiet Translate action
          on a foreign-language card, the pending notice while the worker runs,
          or — never silently — the "Translated from …" label with the original
          one tap away. Events go to the host LiveView (no phx-target). --%>
          <.translation_line
            state={@translation.state}
            offer?={@translation.offer?}
            kind="post"
            subject_id={@post.id}
          />

          <%!-- The action bar (like / repost / bookmark + counters). On a
          LiveView host it is an in-process LiveComponent that re-renders in
          place (no extra process, no per-card PubSub, no flashing inside a
          stream). On a dead controller page — which has no LiveView host — it
          is the standalone `Actions` LiveView, embedded so its counters still
          tick. The id derives from the timeline entry, not the post: the same
          post can render twice on one page (original + repost). --%>
          <%= if match?(%Phoenix.LiveView.Socket{}, @conn_or_socket) do %>
            <.live_component
              module={VutuvWeb.PostLive.ActionsComponent}
              id={@actions_id}
              post_id={@post.id}
              viewer_id={@viewer_id}
              acting_as_id={@acting_as_id}
              engagement={@engagement}
            />
          <% else %>
            {live_render(@conn_or_socket, VutuvWeb.PostLive.Actions,
              id: @actions_id,
              session: %{"post_id" => @post.id, "id" => @actions_id, "engagement" => @engagement}
            )}
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  The inline `style` string carrying a reader's post-display preferences onto a
  post body as CSS custom properties, or `nil` when the preferences are the
  defaults (so a logged-out reader and a default account emit no inline style
  and fall through to the `.post-clamp` / `.markdown--post` fallbacks).

  Takes the map from `Vutuv.Accounts.User.post_prefs/1`. A `0` line count maps to
  the CSS keyword `none` (unclamp that breakpoint); a `true`/`false` hyphenation
  flag maps to `auto`/`manual`.
  """
  def post_body_style(prefs) do
    if prefs == User.post_prefs_defaults() do
      nil
    else
      IO.iodata_to_binary([
        "--post-clamp-desktop:",
        clamp_value(prefs.lines_desktop),
        ";--post-clamp-mobile:",
        clamp_value(prefs.lines_mobile),
        ";--post-hyphens-desktop:",
        hyphens_value(prefs.hyphenate_desktop),
        ";--post-hyphens-mobile:",
        hyphens_value(prefs.hyphenate_mobile)
      ])
    end
  end

  defp clamp_value(0), do: "none"
  defp clamp_value(n) when is_integer(n), do: Integer.to_string(n)

  defp hyphens_value(true), do: "auto"
  defp hyphens_value(false), do: "manual"

  # `style` is a HEEx special attribute that is always emitted — `style={nil}`
  # renders a stray `style=""` — so a default reader would carry an empty style
  # on every post body. Splat this instead (`{style_attrs(@body_style)}`): an
  # empty list adds nothing, a value adds the one attribute.
  defp style_attrs(nil), do: []
  defp style_attrs(style), do: [style: style]

  # The clamped preview body: the Markdown cut by the `.post-clamp` line clamp
  # (the reader's per-breakpoint line budget, default 6 desktop / 8 mobile, fed
  # in via @body_style), faded out at the bottom, with a "Read more" affordance
  # riding the last line.
  #
  # The fade is a mask on this body (components.css), not an overlay element, so
  # it lands on the cut in the height-clamping wrap/media variants too — those
  # cut mid-line, since a post body's paragraph margins make the box more than N
  # whole line boxes, and the slice used to be shown bare.
  #
  # The WHOLE body is always in the DOM (post_card renders it uncut for every
  # preview) and is merely CSS-clamped, so "Read more" is a single in-place
  # **toggle button** (`data-post-expand`): clicking it drops the clamp and
  # reveals the rest of the text with a short height animation, then flips its
  # own label to "Show less" so the reader can fold it back — no navigation, no
  # reload (app.js `togglePreviewExpand`). Feed and profile behave identically;
  # a long post expands in place just like a short one.
  #
  # Visibility is driven entirely by the wrapper's `is-clamped` / `is-expanded`
  # state (component CSS in components.css), NOT by `hidden`/`inline-block`
  # display utilities on the control — so the #880 two-competing-display-utilities
  # trap (a control carrying both `hidden` and `inline-block`, the later-emitted
  # `.inline-block` silently winning) cannot recur. A css-only clamp is width-
  # and font-dependent, so the server never marks the body cut: the
  # PostPreviewClamp hook (live pages) / data-post-preview sweep (dead pages)
  # sets `is-clamped` when the body overflows (standard test: body scrollHeight
  # exceeds clientHeight). With JS off a css-only clamp keeps the native ellipsis
  # and no control. Shared by the full-width preview and the 2/3 side-by-side
  # layout, so the clamp behaves identically whichever column width it lands in;
  # `class` carries the caller's top margin (mt-2 standalone, none in the flex row).
  attr(:body_id, :string, required: true)
  attr(:body_html, :any, required: true)
  attr(:body_style, :string, default: nil)
  # The prose's own type and colour ride HERE, on the wrapper, and are inherited
  # by the clamp body — never put a `text-*` or `leading-*` on the body itself.
  # `.post-clamp--wrap` measures its budget in `lh`, which is only portable while
  # the body declares no type of its own (see the note beside that rule in
  # components.css), so a size on the body would cut the same post at two
  # different places in Chrome and WebKit.
  attr(:class, :any, default: nil)
  # Wrap mode: a small image/screenshot floats beside the body (the `:float`
  # slot) and the text flows around AND below it. `-webkit-line-clamp` cannot wrap
  # around a float, so wrap mode clamps by height (`.post-clamp--wrap`) inside a
  # float-containing block — see components.css.
  attr(:wrap, :boolean, default: false)
  # Media mode: the body itself carries inline post images (`![](…)` own-upload
  # references), which a line clamp cannot hold either — same height-clamp
  # mechanics as wrap mode (shared `post-preview--wrap` control styling), but
  # with a media allowance on top of the text budget (`.post-clamp--media`) so
  # the picture the author placed is visible on the feed, not below the fold.
  attr(:media, :boolean, default: false)
  # The post's tag chips. In the flow-root variants (wrap/media — the ones that
  # can carry a float) they render INSIDE the clamp block so they follow the end
  # of the text beside a tall floated image (like full mode since v7.110.3),
  # plus a CSS-toggled fallback row below the block that stands in while the
  # body is clamped — inside the clamp the inline row would be cut away with
  # the text (see the `.post-preview__tags-*` rules in components.css). The
  # line-clamp variant ignores them (a -webkit-box cannot hold the chips row;
  # there is no float there, so the caller's plain row below already sits at
  # the end of the text).
  attr(:tags, :list, default: [])
  # The body's language (BCP47 primary subtag) for the `lang` attribute —
  # screen readers and hyphenation; nil renders no attribute.
  attr(:lang, :string, default: nil)
  slot(:float)

  defp preview_body(assigns) do
    ~H"""
    <div
      id={@body_id}
      phx-hook="PostPreviewClamp"
      data-post-preview
      class={["post-preview", (@wrap or @media) && "post-preview--wrap", @class]}
    >
      <div class="relative">
        <div
          class={[
            cond do
              @media -> "post-clamp--media"
              @wrap -> "post-clamp--wrap"
              true -> "post-clamp"
            end,
            "markdown markdown--post"
          ]}
          data-clamp-body
          data-post-body
          lang={@lang}
          {style_attrs(@body_style)}
        >
          <%!-- The floated media is the clamp block's FIRST child so the body text
          wraps around it; the block contains + clips it (flow-root + overflow). --%>
          {render_slot(@float)}
          {@body_html}
          <.post_tags :if={@wrap or @media} tags={@tags} class="post-preview__tags-inline" />
        </div>
        <%!-- The cut fades out (a mask on the clamp body itself, gated on the
        `is-clamped` the hook sets — see components.css), so it needs no overlay
        element here and works the same in every clamp variant. --%>
        <%!-- The whole body is present, so "Read more" expands it in place. --%>
        <button
          type="button"
          data-read-more
          data-post-expand
          aria-expanded="false"
          aria-controls={@body_id}
          data-label-more={gettext("Read more")}
          data-label-less={gettext("Show less")}
          class="post-preview__more text-sm font-medium text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
        >
          {gettext("Read more")}
        </button>
      </div>
      <.post_tags :if={@wrap or @media} tags={@tags} class="post-preview__tags-below" />
    </div>
    """
  end

  # The post's tag chips row. Renders nothing when there are no tags, so callers
  # drop it in unconditionally. `class` replaces the default utility row when the
  # row's layout must live in components.css instead: the preview rows toggle
  # their `display` by clamp state, and a `flex` utility here would beat those
  # layered rules in the cascade.
  attr(:tags, :list, required: true)
  attr(:class, :string, default: "mt-3 flex flex-wrap gap-2")

  defp post_tags(assigns) do
    ~H"""
    <%!-- no-underline: inside the full-mode/preview body the row sits in
    `.markdown`, whose `a { text-decoration: underline }` would underline the
    chips; the utility wins over the components-layer rule and is a no-op
    elsewhere. --%>
    <div :if={@tags != []} class={@class}>
      <.chip :for={tag <- @tags} navigate={~p"/tags/#{tag}"} class="no-underline">{tag.name}</.chip>
    </div>
    """
  end

  # The attachment gallery below the body: images the body does NOT reference
  # inline (`![](…)`).
  #
  # The two modes show the same photos with deliberately different priorities
  # (issue #1104):
  #
  #   * **`:preview`** (feed, profile) is a glance. Several photos lay
  #     themselves out as an aspect-aware **bento mosaic** of a capped height,
  #     so a nine-photo post takes up as much of the timeline as a one-photo
  #     post and the whole set reads in one look. A tile opens the permalink.
  #
  #   * **`:full`** (the permalink) is the show. Photos keep their **natural
  #     aspect ratio** — no crop — so a portrait, a panorama and a screenshot
  #     each read whole; one fills the column, several tile 2-up from `sm`.
  #     A tile opens the lightbox.
  #
  # The `feed` image version is already aspect-preserving (`box_down 1200`), so
  # `w-full` alone shows it uncropped in full mode.
  attr(:gallery, :list, required: true)
  attr(:mode, :atom, required: true, values: [:preview, :full])
  attr(:permalink, :string, required: true)
  attr(:license, :string, default: nil, doc: "the post's license, for the lightbox panel")
  attr(:layout, :string, default: nil, doc: "the post's chosen bento arrangement; nil = auto")
  attr(:fill, :boolean, default: false, doc: "tiles filled (cropping) vs whole photos")

  defp post_gallery(%{mode: :preview} = assigns), do: mosaic(assigns)

  defp post_gallery(assigns) do
    ~H"""
    <.lightbox_gallery class={["grid gap-2 mt-4", length(@gallery) > 1 && "sm:grid-cols-2"]}>
      <figure
        :for={{image, index} <- Enum.with_index(@gallery)}
        class="mb-0 overflow-hidden rounded-lg ring-1 ring-slate-200 dark:ring-slate-800"
      >
        <.lightbox_link
          image={image}
          index={index}
          count={length(@gallery)}
          license={@license}
          class="block"
        >
          <img
            src={PostImage.url(image, "feed")}
            alt={photo_alt(image)}
            width={image.width}
            height={image.height}
            loading="lazy"
            class="w-full object-cover"
          />
        </.lightbox_link>
        <figcaption
          :if={present?(image.caption)}
          class="px-3 py-2 text-sm text-slate-600 dark:text-slate-400"
        >
          {image.caption}
        </figcaption>
      </figure>
    </.lightbox_gallery>
    """
  end

  @doc """
  The **bento mosaic**: two or more photos laid out from their own aspect
  ratios into one tile arrangement of a fixed, capped height (issue #1104).

  Three things it is built around:

    * **The first photo is the hero.** It gets the big tile, so reordering in
      the composer is the whole layout control an author needs — no
      tile-size editor.

    * **The layout follows the shapes.** A portrait hero gets a tall
      left-hand tile and the pixelated preview a portrait-ish frame; a landscape hero
      gets a wide top tile and a landscape frame
      (`VutuvWeb.PostComponents.mosaic_layout/1`). By default every photo
      shows **whole**, letterboxed inside its tile (`fill={false}`); the
      author can switch the tiles to *filled* instead, where the photo covers
      its tile and is cropped by it — and choosing the frame from the photos
      is what keeps that crop gentle instead of chopping every picture to one
      hardcoded band. Either way the orientation-tuned frames matter: they
      minimise the letterboxing or the crop alike.

    * **It stays one glance tall.** At most five tiles show; a sixth and
      beyond fold into a `+N` on the last one, and the whole block is capped,
      so a photo essay costs the same timeline height as a snapshot.

  Every tile opens the post; the photos themselves are shown whole on the
  permalink, which is where the lightbox lives.
  """
  # No `:global` rest attr on purpose: `post_gallery/1` delegates here with its
  # own assigns, and a global would collect its `mode` and `license` and emit
  # them as stray `mode="preview" license="arr"` attributes on the anchor.
  attr(:gallery, :list, required: true)
  attr(:permalink, :string, required: true)
  attr(:layout, :string, default: nil)
  attr(:fill, :boolean, default: false)

  def mosaic(assigns) do
    layout = mosaic_layout(assigns.gallery, assigns.layout)

    assigns = assigns |> assign(:cells, layout.cells) |> assign(:frame, layout.aspect)

    ~H"""
    <.link
      href={@permalink}
      aria-label={gettext("View post")}
      class="mt-3 grid gap-1 overflow-hidden rounded-lg"
      style={"aspect-ratio: #{@frame}; grid-template-columns: repeat(12, 1fr); grid-template-rows: repeat(6, 1fr); max-height: 44rem"}
      data-post-mosaic={length(@gallery)}
    >
      <div
        :for={cell <- @cells}
        class="relative overflow-hidden bg-slate-100 ring-1 ring-slate-200 dark:bg-slate-800 dark:ring-slate-800"
        style={"grid-area: #{cell.area}"}
      >
        <%!-- Whole photos by default: object-contain letterboxes a photo
        inside its tile instead of cropping it — nobody's picture loses its
        edges unless the author switched the tiles to "filled". --%>
        <img
          src={PostImage.url(cell.image, "feed")}
          alt={photo_alt(cell.image)}
          loading="lazy"
          class={["h-full w-full", (@fill && "object-cover") || "object-contain"]}
        />
        <%!-- The overflow badge sits on the last visible tile and dims it, so
        the count reads as "there are more behind this" rather than as a label
        stuck on one particular photo. --%>
        <span
          :if={cell.more > 0}
          class="absolute inset-0 flex items-center justify-center bg-slate-900/55 text-2xl font-semibold text-white"
          data-mosaic-more
        >
          +{compact_count(cell.more)}
        </span>
      </div>
    </.link>
    """
  end

  # How many tiles a pixelated preview draws before the rest collapse into the `+N`.
  # Five is what the layouts below are drawn for, and the point past which
  # tiles get too small to be worth loading.
  @mosaic_tiles 5

  @doc """
  The tile arrangement for a photo set: `%{aspect: "7 / 5", cells: [...]}`,
  each cell carrying its image, its CSS `grid-area` on the shared 12×6 grid
  and how many further photos it stands for (`more`, non-zero on the last tile
  only).

  `layout` names a `Vutuv.Posts.GalleryLayout` variant the author chose in the
  composer; `nil` (and any name unavailable at this count) keeps the automatic
  orientation-driven choice the pixelated preview always made.

  Public so `mosaic_layout_test.exs` can check the geometry directly — the
  arrangement is the feature, and it is much easier to get wrong than to see
  wrong.
  """
  def mosaic_layout(gallery, layout \\ nil) do
    shown = Enum.take(gallery, @mosaic_tiles)
    more = length(gallery) - length(shown)
    hero = List.first(shown)
    tall? = hero && PostImage.orientation(hero) == :portrait

    {aspect, areas} = mosaic_shape(length(shown), tall?, layout)

    cells =
      shown
      |> Enum.zip(areas)
      |> Enum.with_index()
      |> Enum.map(fn {{image, area}, index} ->
        %{image: image, area: area, more: if(index == length(shown) - 1, do: more, else: 0)}
      end)

    %{aspect: aspect, cells: cells}
  end

  # The arrangements live in `Vutuv.Posts.GalleryLayout` — a named catalog on
  # the shared 12×6 grid, so the composer can offer them as a choice. What is
  # tuned there is the hero cell, not the frame: a cell's aspect is
  # `frame_ratio × (cell_cols / 12) ÷ (cell_rows / 6)`, so the frame and the
  # hero's own tile pull in opposite directions — a portrait hero wants a
  # *wider* frame when its tile is narrow and full-height. That is the whole
  # "aspect-aware" claim, and it holds for a chosen arrangement too: the
  # variant names where the tiles sit, the frame still follows the hero.
  # `mosaic_layout_test.exs` asserts the resulting hero-cell shape.
  defp mosaic_shape(count, tall?, layout) when count >= 2 do
    variant =
      GalleryLayout.variant(count, layout) || GalleryLayout.auto_variant(count, tall?)

    {GalleryLayout.frame(variant, tall? == true), variant.areas}
  end

  # A single tile (and the defensive zero case) simply fills the frame; the
  # post card routes one photo to its own full-width treatment before it ever
  # gets here.
  defp mosaic_shape(_count, tall?, _layout) do
    {if(tall?, do: "4 / 5", else: "3 / 2"), ["1 / 1 / 7 / 13"]}
  end

  @doc """
  One photo as a lightbox-opening link.

  With JavaScript the `data-photo-*` attributes are all the overlay needs to
  render the picture, its caption, the camera panel, the download and the
  license — so the lightbox reads the page rather than being fed a second
  copy of the data. Without JavaScript the same element is a plain link to
  the full-size image, which is what it was before the lightbox existed.
  """
  attr(:image, :any, required: true)
  attr(:index, :integer, required: true)
  attr(:count, :integer, required: true)
  attr(:license, :string, default: nil)
  attr(:class, :string, default: nil)
  slot(:inner_block, required: true)

  def lightbox_link(assigns) do
    assigns =
      assigns
      |> assign(:camera, PostImage.show_camera_info?(assigns.image) && camera_line(assigns.image))
      |> assign(:download, PostImage.download_url(assigns.image))

    ~H"""
    <a
      href={PostImage.url(@image, "xl")}
      class={@class}
      data-lightbox-photo={@index}
      data-photo-src={PostImage.url(@image, "xl")}
      data-photo-alt={photo_alt(@image)}
      data-photo-caption={@image.caption}
      data-photo-camera={@camera}
      data-photo-download={@download}
      data-photo-license={@license && license_label(@license)}
      data-photo-license-url={@license && PhotoLicense.url(@license)}
      data-photo-position={gettext("Photo %{n} of %{total}", n: @index + 1, total: @count)}
    >
      {render_slot(@inner_block)}
    </a>
    """
  end

  @doc """
  The camera line under a photo, e.g.
  "Canon EOS R6 · 50 mm · f/1.8 · 1/200 s · ISO 400 · 25 July 2026".

  The capture date joins the technical facts here rather than being a field of
  its own: on a photo it is one more fact about the shot, not the post's
  timestamp (which the card already shows).
  """
  def camera_line(%PostImage{} = image) do
    [PostImage.camera_summary(image), taken_on(image)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp taken_on(%PostImage{taken_at: nil}), do: nil

  # The capture day only — a shutter time to the second is noise beside the
  # exposure settings. Written in the reader's own region, like the post
  # timestamp above it (`VutuvWeb.UI.post_time/1`), so dates read the same
  # across the card. The capture day is the photographer's local day as their
  # camera recorded it, so it is never shifted into the reader's zone.
  defp taken_on(%PostImage{taken_at: taken_at}) do
    taken_at |> NaiveDateTime.to_date() |> Vutuv.ViewerClock.format(:date)
  end

  # Below this a photo is taller than 1:2 — a tower the reader has to scroll
  # past rather than look at — and is cropped to an ordinary frame instead.
  # There is deliberately no counterpart for wide photos; see the doc below.
  @whole_ratio_min 0.5

  @doc """
  How a lone photo is fitted into a feed card (issue #1104): `:whole`, or
  `{:crop, aspect}` for a shape too extreme to show at column width.

  **A single photo is not cropped.** The old card forced every one into a
  24rem-tall `object-cover` box, which cut the top and bottom off any portrait
  — the shape a phone takes by default. Now a photo is shown complete and
  merely bounded in height, so it can be *smaller* than the column but never a
  fragment of itself.

  The one exception is a photo taller than **1:2**: at column width that is not
  a picture you look at but a scroll you get past, so it is cropped to 3:4 and
  the permalink shows it whole.

  **Width has no such limit, and that asymmetry is the point.** A wide photo
  cropped to 2:1 used to be the mirror rule, on the reasoning that a panorama
  at column width is a letterbox slit. It isn't: the column bounds the width,
  so a wide frame is merely *flat*, and nothing about it costs the timeline
  anything. What the crop did cost was content, always from the right-hand
  edge — a 1572×424 screenshot of a news teaser lost the headline and the
  teaser text in the feed while the permalink showed them, which reads as two
  different renderings of one post. Height is a budget the card has to defend;
  width is not.

  Public for `single_photo_fit_test.exs`: the boundary is the feature, and a
  ratio rule is the kind of thing that reads correct and is off by a factor.
  """
  def feed_photo_fit(%PostImage{} = image) do
    if PostImage.aspect(image) < @whole_ratio_min do
      {:crop, "3 / 4"}
    else
      :whole
    end
  end

  @doc """
  The lone photo on a feed card, fitted per `feed_photo_fit/1`.

  A whole photo is bounded by **height**, not width: `max-h` with an auto
  width lets the browser scale it down until it fits, so a portrait keeps its
  full frame and simply occupies a narrower centred column instead of running
  a thousand pixels down the timeline. A cropped one fills the width in a
  fixed frame, where `object-cover` is the right tool because the crop is the
  point.
  """
  attr(:image, :any, required: true)

  def single_feed_photo(assigns) do
    assigns = assign(assigns, :fit, feed_photo_fit(assigns.image))

    ~H"""
    <img
      :if={@fit == :whole}
      src={PostImage.url(@image, "feed")}
      alt={photo_alt(@image)}
      width={@image.width}
      height={@image.height}
      loading="lazy"
      class="mx-auto max-h-[32rem] w-auto max-w-full rounded-lg ring-1 ring-slate-200 dark:ring-slate-800"
      data-photo-fit="whole"
    />
    <img
      :if={@fit != :whole}
      src={PostImage.url(@image, "feed")}
      alt={photo_alt(@image)}
      loading="lazy"
      style={"aspect-ratio: #{elem(@fit, 1)}"}
      class="w-full rounded-lg object-cover ring-1 ring-slate-200 dark:ring-slate-800"
      data-photo-fit="crop"
    />
    """
  end

  # One tile standing where a photo will be once the AI scan has released it
  # (issue #1720). Two shapes, and which one a reader gets depends on nothing
  # they can see:
  #
  #   * the photo's own pixelated preview — a separately stored file, 64 cells
  #     across, never a CSS filter over the real picture
  #     (`Vutuv.Moderation.Pixelation` explains why that distinction is the whole
  #     point). The card keeps its shape and its colours, and the live broadcast
  #     swaps the picture in.
  #   * the grey hourglass tile, when there is no preview to serve: an
  #     installation that switched it off, a wait that has run past its window,
  #     a picture stored before this existed.
  #
  # The tile is not a link and opens no lightbox: there is nothing behind it to
  # enlarge yet. The image carries an empty `alt` because it is decorative in
  # the literal sense — the badge beside it is the information, and inventing a
  # description of a picture nobody has looked at yet would be a lie in the one
  # place a reader cannot check it.
  attr(:image, :map, required: true, doc: "the held %Vutuv.Posts.PostImage{}")

  defp held_photo(assigns) do
    assigns = assign(assigns, :pixelated_url, Posts.image_pixelated_url(assigns.image))

    ~H"""
    <div
      :if={@pixelated_url}
      class="relative overflow-hidden rounded-lg ring-1 ring-slate-200 dark:ring-slate-700"
      data-image-pixelated
    >
      <img src={@pixelated_url} alt="" loading="lazy" class="block aspect-[4/3] w-full object-cover" />
      <.checking_badge />
    </div>
    <div
      :if={!@pixelated_url}
      class="flex aspect-[4/3] w-full flex-col items-center justify-center gap-2 rounded-lg bg-slate-100 px-3 text-center ring-1 ring-slate-200 dark:bg-slate-800 dark:ring-slate-700"
    >
      <.hourglass class="h-7 w-7 text-slate-500 dark:text-slate-400" />
      <span class="text-xs font-semibold text-slate-700 dark:text-slate-200">
        {gettext("Photo is being checked")}
      </span>
    </div>
    """
  end

  @doc """
  The author's "we are checking your photos" banner (issue #1104).

  The post itself is published the moment it is written; only the picture waits
  for the AI scan. So this banner carries the one fact the author would
  otherwise get wrong — **the post is already out there, the photo is not** —
  then that a check is running right now (the turning hourglass), then how far
  it has got on a multi-photo post ("2 of 5 done"). It disappears by itself the
  moment the last photo clears, which is the answer to "when does the picture
  show up".

  It says the opposite of what it said when this feature shipped ("only you can
  see this post so far"), and that is the whole point of the change: holding the
  text back until the picture was vetted meant a reply carrying a photo raised a
  notification for a post nobody could then find.

  Author-only. Every other reader is told the same thing by the placecard
  standing where the picture goes, in words that fit a stranger.

  Deliberately a banner on the card and not a modal: the check takes as long as
  it takes, and the author is meant to keep working meanwhile.

  It is `role="status"`, so a screen reader hears each step as the count
  updates rather than only on arrival.
  """
  attr(:progress, :map, required: true, doc: "Vutuv.Posts.image_check_progress/1")

  def photo_check_progress(assigns) do
    ~H"""
    <div
      class="mt-2 flex items-start gap-2 rounded-lg bg-amber-50 px-3 py-2 text-xs text-amber-800 ring-1 ring-amber-200 dark:bg-amber-900/30 dark:text-amber-200 dark:ring-amber-800"
      role="status"
      aria-live="polite"
      data-image-pending-pill
      data-check-pending={@progress.pending}
    >
      <.hourglass class="mt-0.5 h-4 w-4" />
      <span>
        <span class="font-semibold">
          {gettext("Your post is published, the photo is not there yet.")}
        </span>
        <span class="mt-0.5 block">
          {ngettext(
            "Our AI is still checking it. As soon as it is through, the photo appears by itself.",
            "Our AI is still checking them, %{done} of %{total} done. As soon as the last one is through, the photos appear by themselves.",
            @progress.total,
            done: @progress.checked,
            total: @progress.total
          )}
        </span>
      </span>
    </div>
    """
  end

  @doc "The license label, from the one vocabulary that owns it."
  def license_label(license), do: PhotoLicense.label(license)

  @doc """
  The permalink's rights line under a photo set: the license, linked to its
  deed so a reader can check the actual terms rather than trust a label.

  Renders **nothing** for all-rights-reserved. That is the default every post
  carries, so showing it would put a rights notice on every picture on the
  site and teach people to stop reading the line — which is precisely the
  line that has to be read on the posts where an author did grant something.
  """
  attr(:license, :string, required: true)

  def photo_license_line(assigns) do
    ~H"""
    <p
      :if={PhotoLicense.grants_reuse?(@license)}
      class="mt-2 text-xs text-slate-600 dark:text-slate-400"
      data-photo-license={@license}
    >
      {gettext("Photos:")}
      <.link
        href={PhotoLicense.url(@license)}
        target="_blank"
        rel="license noopener"
        class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
      >
        {license_label(@license)}
      </.link>
    </p>
    """
  end

  # A photo with no alt text still needs an accessible name when it has a
  # caption: the caption is at least *about* the picture, which beats an empty
  # string a screen reader announces as an unlabelled image. An alt the author
  # wrote always wins.
  defp photo_alt(%PostImage{alt: alt}) when is_binary(alt) and alt != "", do: alt
  defp photo_alt(%PostImage{caption: caption}) when is_binary(caption), do: caption
  defp photo_alt(%PostImage{}), do: ""

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  # The "Reposted by" attribution line: an overlapping avatar stack (the
  # reposters the viewer follows, newest first) plus a sentence naming the
  # newest one. The stack shows at most `@repost_stack_cap` faces; a further
  # `+N` chip stands in for the rest, so a wildly-reposted post stays a tidy
  # one-line strip instead of a wall of avatars. Callers with a single
  # reposter (the profile Posts section, the dead archive/permalink lists)
  # pass a one-element roster, which folds into one avatar and the plain
  # "Reposted by NAME" — byte-compatible with the old single-name banner.
  attr(:reposters, :list, required: true)

  attr(:reposters_total, :integer,
    default: nil,
    doc: "the uncapped count behind the roster; nil means the list is all of them"
  )

  # The banner's avatar stack: single-reposter callers (the profile, the dead
  # archive/permalink lists) pass only `reposted_by`, which folds into a
  # one-avatar roster; the feed passes the whole `reposters` list.
  defp repost_roster(%{reposters: reposters}) when is_list(reposters), do: reposters
  defp repost_roster(%{reposted_by: reposted_by}), do: List.wrap(reposted_by)

  # Whether pinning this post would push another one off the profile — the
  # author already pins a different post (issue #1110). Read off the preloaded
  # author, so it costs no query.
  defp pin_replaces_other?(%{user: %User{pinned_post_id: pinned_id}, id: id})
       when is_binary(pinned_id),
       do: pinned_id != id

  defp pin_replaces_other?(_post), do: false

  # The pushpin marking the post a member showcases on their profile (issue
  # #1110). Private to this module by convention: the pin is a post idea, and
  # the profile headline pin has its own star (`VutuvWeb.UserHelpers.pin_star/1`).
  attr(:class, :string, default: "h-5 w-5")

  defp icon_pin(assigns) do
    ~H"""
    <svg
      class={@class}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.5"
      aria-hidden="true"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M12 14.25v6.75M8.25 3.75h7.5l-.9 4.5 2.4 2.4v1.6H6.75v-1.6l2.4-2.4-.9-4.5Z"
      />
    </svg>
    """
  end

  defp reposted_banner(%{reposters: []} = assigns), do: ~H""

  defp reposted_banner(assigns) do
    reposters = assigns.reposters

    # The roster is capped (`Vutuv.Posts.reposter_roster_cap/0`), so the tail is
    # counted from the total the query reported and never from the list's own
    # length — otherwise a post reshared two thousand times would say "and 4
    # others". A caller that passes no total (the profile, the dead archive and
    # permalink lists, each with a single resharer) has the list as its total.
    total = assigns.reposters_total || length(reposters)

    assigns =
      assigns
      |> assign(:primary, hd(reposters))
      |> assign(:cap, @repost_stack_cap)
      |> assign(:total, total)
      # Everyone besides the named (newest) reposter — the "and N others" tail.
      |> assign(:others, total - 1)

    ~H"""
    <div
      class="mb-3 flex items-center gap-2 text-xs font-semibold text-slate-600 dark:text-slate-400"
      data-reposted-by={@primary.id}
    >
      <.icon_repost class="h-4 w-4 shrink-0" />
      <%!-- The stack's avatars link to each reposter; the sentence beside it
      names them, so the stack itself is decorative for assistive tech. --%>
      <.avatar_stack users={@reposters} cap={@cap} total={@total} />
      <span class="min-w-0 truncate">
        <%!-- `author_name/1` / `author_path/1`, not `full_name/1` / `~p`: a
        reposter can be a page (`Posts.reposter_rosters/2`), which crashed the
        member-only pair (issue #1410). --%>
        <%= if @others == 0 do %>
          <.link href={Posts.author_path(@primary)} class="hover:text-brand-700 dark:hover:text-brand-300">
            {gettext("Reposted by %{name}", name: UserHelpers.author_name(@primary))}
          </.link>
        <% else %>
          {ngettext(
            "Reposted by %{name} and %{formatted} other",
            "Reposted by %{name} and %{formatted} others",
            @others,
            name: UserHelpers.author_name(@primary),
            formatted: compact_count(@others)
          )}
        <% end %>
      </span>
    </div>
    """
  end

  # **Who** liked this post (issue #1233), on the permalink only: the faces of
  # the members whose `like_attribution?` preference lets this reader see them,
  # and a sentence naming the newest one.
  #
  # Until now a like was a number, and the one moment an author ever learned
  # who was behind it was the notification — a month later the answer lived in
  # an old notification list. A favourite from another network, meanwhile, has
  # named its account right here on the card since issue #1068, so vutuv's own
  # members were the one anonymous half of a post's likes.
  #
  # Three things it deliberately does **not** do. It does not move the **count**:
  # the `+N` chip is the difference between the total the button shows and the
  # faces beside it, so a member's private choice never shrinks somebody else's
  # tally and the chip leaks nothing past a figure that was already public. It
  # does not appear on a **feed** card: a per-card avatar row down a long
  # timeline is a query-batching problem and visual noise. And it does not lead
  # to a **likes subpage** — one row of faces is the whole feature.
  #
  # `private?` is the author's case: they see members who opted out of being
  # named (we told them the name in the like notification at the time, so
  # hiding it afterwards would be a promise we could not keep), and the line
  # under the row says so rather than letting them read the row as public.
  #
  # Spaced rather than shingled, and `xs` rather than the `2xs` of the repost
  # banner: these are people the reader may well want to look up, so each face
  # is a finger-sized target and a picture-less member's monogram stays whole.
  # The translation line's three states (issue #1462): the shown label ("never
  # a silent translation"), the pending notice, or the quiet Translate action.
  # Never more than one renders. Events carry the subject as kind + id and go
  # to the host LiveView, which owns the translations map.
  attr(:state, :any, doc: "nil | :pending | %Vutuv.Translations.Translation{} (= shown)")
  attr(:offer?, :boolean, doc: "whether an untranslated card gets the Translate action")
  attr(:kind, :string, doc: "\"post\" / \"remote_post\" / \"note\"")
  attr(:subject_id, :any)

  defp translation_line(assigns) do
    ~H"""
    <p
      :if={match?(%Translation{}, @state)}
      class="mt-2 flex flex-wrap items-center gap-x-1.5 text-xs text-slate-600 dark:text-slate-400"
      data-translation-label
    >
      {translated_from_label(@state)}
      <span aria-hidden="true">·</span>
      <button
        type="button"
        phx-click="show-original"
        phx-value-kind={@kind}
        phx-value-id={@subject_id}
        class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
      >
        {gettext("Show the original")}
      </button>
      <span aria-hidden="true">·</span>
      <%!-- The way back to the settings, from the one place a reader ever
      wonders about them (issue #1672). A translated card is the whole
      feature made visible, and until now nothing on it said where the
      behaviour is decided — a member would have had to guess that "feed
      languages" lives under Settings at all. Named after the page it opens
      rather than a bare cog, because the point is to be findable; it is one
      short word on a line that already wraps. --%>
      <.link
        navigate={~p"/settings/feed_languages"}
        data-translation-settings
        class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
      >
        {gettext("Feed languages")}
      </.link>
    </p>
    <p
      :if={@state == :pending}
      role="status"
      class="mt-2 flex items-center gap-1.5 text-xs text-slate-600 dark:text-slate-400"
      data-translation-pending
    >
      <.hourglass class="h-3.5 w-3.5 text-slate-400 dark:text-slate-500" />
      {gettext("Translating…")}
    </p>
    <p :if={is_nil(@state) and @offer?} class="mt-2">
      <button
        type="button"
        phx-click="translate"
        phx-value-kind={@kind}
        phx-value-id={@subject_id}
        data-translate-button
        class="text-xs font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
      >
        {gettext("Translate")}
      </button>
    </p>
    """
  end

  # "und" is the model's honest "could not tell" — a label naming no language
  # beats one confidently naming the wrong one.
  defp translated_from_label(%Translation{source_language: source}) when source in [nil, "und"],
    do: gettext("Translated")

  defp translated_from_label(%Translation{source_language: source}),
    do: gettext("Translated from %{language}", language: Languages.name(source))

  # The shown translation's content warning, else the original — a warning
  # must never silently vanish just because its translation lacks one.
  defp translated_summary(%{state: %Translation{summary: summary}}, _original)
       when is_binary(summary) and summary != "",
       do: summary

  defp translated_summary(_translation, original), do: original

  # One card's translation view-state, computed in one place for all three
  # card kinds: what the body renders from, which language it is in, and
  # whether the Translate action shows. A nil translations map means this
  # viewer gets no controls at all (every non-LiveView surface).
  defp card_translation(assigns, key, original_body, original_language) do
    state = assigns.translations[key]
    shown = if match?(%Translation{}, state), do: state

    %{
      state: state,
      body_source: if(shown, do: shown.body, else: original_body),
      lang: if(shown, do: shown.target_language, else: original_language),
      offer?:
        is_map(assigns.translations) and
          PostTranslations.offer_translation?(original_language, assigns.viewer)
    }
  end

  attr(:likers, :map, required: true)

  defp liked_by(%{likers: %{users: []}} = assigns), do: ~H""

  defp liked_by(assigns) do
    likers = assigns.likers
    total = max(likers.total, length(likers.users))

    assigns =
      assigns
      |> assign(:primary, hd(likers.users))
      |> assign(:total, total)
      |> assign(:others, total - 1)

    ~H"""
    <div class="mt-3" data-post-likers={@total}>
      <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
        <%!-- The faces link to each member; the sentence beside them names the
        newest, so the stack itself is decoration for assistive tech. --%>
        <.avatar_stack
          users={@likers.users}
          total={@total}
          size="xs"
          overlap={false}
          cap={Posts.likers_shown()}
        />
        <span class="min-w-0 text-sm text-slate-600 dark:text-slate-400">
          <%!-- `author_name/1`, not `full_name/1`: the newest liker can be a
          page (issue #1410), and `full_name/1` has no clause for one. --%>
          <%= if @others == 0 do %>
            {gettext("Liked by %{name}", name: UserHelpers.author_name(@primary))}
          <% else %>
            {ngettext(
              "Liked by %{name} and %{formatted} other",
              "Liked by %{name} and %{formatted} others",
              @others,
              name: UserHelpers.author_name(@primary),
              formatted: compact_count(@others)
            )}
          <% end %>
        </span>
      </div>
      <p :if={@likers.private?} class="mt-1 text-xs text-slate-600 dark:text-slate-400">
        {gettext(
          "Only you see everyone here: some of these members are not named to other readers."
        )}
      </p>
    </div>
    """
  end

  # The three banner states a reply card can be in, resolved from the
  # preloaded reply_ref (one level deep — `Vutuv.Posts.post_preloads/0`).
  # Pattern-match the structs: an un-preloaded has_one is a truthy
  # %Ecto.Association.NotLoaded{}. `show?` is false where the caller already
  # shows the parent post inline (the profile thread), so the banner is dropped.
  defp reply_banner(_post, false, _viewer), do: nil
  defp reply_banner(post, true, viewer), do: reply_banner(post, viewer)

  defp reply_banner(post, viewer) do
    case Posts.reply_ref_state(post) do
      # `Posts.author/1`, not `parent.user`: the parent may have been published
      # in a page's name (issue #1336), and the preloads carry both authors so
      # this costs no query.
      {:parent, parent} -> {:parent, Posts.author(parent), Posts.path(parent)}
      # A top-level post that answers a post on another network (issue #1165)
      # has no local parent at all, so its "Replying to" line comes from the
      # sidecar instead. Only ever reached when there is no local reply ref: an
      # answer to a *reply* (issue #1070) is a real reply here and shows the
      # local parent, which is the more useful of the two.
      nil -> remote_reply_banner(post, viewer)
      state -> state
    end
  end

  # The account behind the post, not the post: the line is about *who* is being
  # answered, and its link is the reader's way to that person's page here. It
  # degrades to plain text once our six-month copy of the post has expired,
  # which is also when the account row may have been swept — the handle stays,
  # because the sidecar keeps its own copy of it.
  defp remote_reply_banner(%{remote_reply_ref: %PostRemoteReply{handle: handle} = ref}, viewer)
       when is_binary(handle),
       # The account page behind the link is signed-in only, so a logged-out
       # reader of this answer's public permalink gets the fact without a link
       # into a login wall. The handle is the fact; the link is a convenience.
       do: {:remote, handle, viewer && remote_account_id(ref)}

  defp remote_reply_banner(_post, _viewer), do: nil

  defp remote_account_id(%PostRemoteReply{
         remote_post: %RemotePost{remote_account: %RemoteAccount{id: id}}
       }),
       do: id

  defp remote_account_id(%PostRemoteReply{}), do: nil

  @doc """
  How a post's author is named in prose about answering them — the card's
  "Replying to …" banner and the reply page's heading, which must agree.

  A member is named by their `@handle`: it is their address, and the line is
  about *who* is being answered. A page is named by its **name**, because a page
  has no handle to speak of — the root handle is an optional address it may
  never have claimed, so `@…` would be a gap dressed as a fact (the same reason
  `author_name/1` puts no handle line beside a page's name on the card itself).
  """
  def author_handle(%Organization{name: name}), do: name
  def author_handle(%User{username: username}), do: "@" <> username

  # Whether to float a post's single image beside its body (the text wraps around
  # and below it, `.post-clamp--wrap`) rather than stacking a full-width image
  # below the text. True only in preview mode, with body text for the float to
  # wrap, exactly one image, and that image roughly square (see square_image?/1).
  # Anything else keeps the existing full-width single / multi-image treatment.
  defp square_layout?(post, gallery, :preview) do
    post.body != "" and match?([_], gallery) and square_image?(hd(gallery))
  end

  defp square_layout?(_post, _gallery, _mode), do: false

  # Whether to render the author's amber progress panel. It keys on the
  # post-level flag rather than on the individual pictures, so it cannot
  # disappear on a viewer whose image list happens to be filtered — and it is
  # the AUTHOR's panel, in the author's voice ("your post is published, the
  # photo is not there yet"), so everybody else is excluded. They are not left
  # guessing: the placecard standing where the picture goes says the same thing
  # in words that fit a stranger.
  defp author_photo_check?(post, author?), do: author? and Posts.held_for_image_check?(post)

  # AI-moderation limbo: the author and admins keep seeing a pending image
  # (the proxy serves it to them); everyone else gets a stand-in tile per held
  # photo instead of the image (Vutuv.Moderation.ImageScans). The held photos
  # travel as rows, not as a count, because each one names its own mosaic.
  defp split_gallery(post, viewer) do
    images = if is_list(post.images), do: post.images, else: []

    if Posts.author?(post, viewer) or match?(%User{admin?: true}, viewer) do
      {images, []}
    else
      Enum.split_with(images, &ImageScans.released?(&1.moderation))
    end
  end

  # A "roughly square" image: aspect ratio inside the @square_ratio_min/max
  # envelope. Guards missing dimensions (nil width/height on very old rows) — an
  # image we can't measure is treated as not-square and keeps the full-width path.
  defp square_image?(%PostImage{width: w, height: h})
       when is_integer(w) and is_integer(h) and w > 0 and h > 0 do
    ratio = w / h
    ratio >= @square_ratio_min and ratio <= @square_ratio_max
  end

  defp square_image?(_), do: false

  # The auto link screenshot to render beside/below a post: a ready
  # %PostScreenshot{} when the post has no image attachments, else nil. The plain
  # map patterns guard un-preloaded associations — a bare has_one/has_many is an
  # %Ecto.Association.NotLoaded{}, which matches neither `[]` nor `%PostScreenshot{}`.
  # The auto link screenshot (a ready %PostScreenshot{} for an image-less
  # single-URL post, else nil), the pixelated preview standing in for it while
  # the AI scan is out, and whether the preview lays it beside the text (3/4
  # body, 1/4 screenshot). One helper because it is one question asked once —
  # it used to be asked three times per card, each answer costing a clock read
  # and a `File.exists?`.
  defp assign_link_screenshot(card_assigns, post, mode) do
    {screenshot, pixelated} = link_screenshot(post)

    card_assigns
    |> assign(:link_screenshot, screenshot)
    |> assign(:screenshot_pixelated, pixelated)
    |> assign(:link_screenshot_layout?, screenshot != nil and mode == :preview)
  end

  # `{screenshot_or_nil, pixelated_url_or_nil}` — the capture this card shows and,
  # while the AI scan is still out on it, the preview standing in its place
  # (issue #1720). A held capture with no preview keeps the old behaviour: no
  # slot at all, which on a link card reads as "no preview" rather than as a
  # hole.
  defp link_screenshot(%{images: [], screenshot: %PostScreenshot{} = ps}),
    do: screenshot_slot(ps)

  defp link_screenshot(_post), do: {nil, nil}

  defp screenshot_slot(%PostScreenshot{} = ps) do
    cond do
      PostScreenshot.ready?(ps) -> {ps, nil}
      url = Vutuv.Screenshot.pixelated_url(ps) -> {ps, url}
      true -> {nil, nil}
    end
  end

  # The remote twin of `link_screenshot/1`, for a cached fediverse post: its
  # ready screenshot when the card shows no pictures and the author raised no
  # content warning. The reconcile enforces those on the queue side; this
  # re-check guards a row from before an edit and, via the struct pattern, a
  # caller that did not preload `:screenshot` (NotLoaded matches nothing).
  defp assign_remote_link_screenshot(card_assigns, post, images) do
    {screenshot, pixelated} = remote_link_screenshot(post, images)

    card_assigns
    |> assign(:link_screenshot, screenshot)
    |> assign(:screenshot_pixelated, pixelated)
  end

  defp remote_link_screenshot(%{screenshot: %PostScreenshot{} = ps} = post, []) do
    if RemotePost.warned?(post), do: {nil, nil}, else: screenshot_slot(ps)
  end

  defp remote_link_screenshot(_post, _images), do: {nil, nil}

  # The post's review sidecar, nil when absent — and nil for a nested parent
  # card whose preload chain didn't carry it (NotLoaded must not crash).
  defp review_of(%{review: %PostReview{} = review}), do: review
  defp review_of(_post), do: nil

  # The review card beside the prose: cover (or a kind glyph tile), the kind
  # label, title, creator · year, and the outbound shop/IMDb link. The cover
  # renders for everyone once released; the author additionally sees their
  # own cover while it waits in AI-moderation limbo (the proxy enforces the
  # same rule per request).
  #
  # `aside` is the beside-the-prose layout (see the prose+card row in
  # post_card): from `md` up the card is a narrow right-hand column, so it
  # turns itself from a cover-beside-text row into a cover-above-text stack —
  # at ~2/5 of a post column the side-by-side halves would each be too narrow
  # to read.
  attr(:review, PostReview, required: true)
  attr(:author?, :boolean, default: false)
  attr(:aside, :boolean, default: false)

  defp review_card(assigns) do
    review = assigns.review

    cover_url =
      if PostReview.cover_ready?(review) or
           (assigns.author? and review.cover_status == "ready" and is_binary(review.cover)) do
        ReviewCover.url(review)
      end

    assigns =
      assigns
      |> assign(:cover_url, cover_url)
      |> assign(:cover_source_url, cover_source_url(review))
      |> assign(:external_url, review_external_url(review))
      |> assign(:isbn, review_isbn(review))
      |> assign(:pages, review_pages_short(review))
      |> assign(:pages_note, review_pages_note(review))
      |> assign(:duration, review_duration_label(review))

    ~H"""
    <div
      class={[
        "mt-3 rounded-xl bg-slate-50 p-3 ring-1 ring-slate-200 dark:bg-slate-800/50 dark:ring-slate-700",
        @aside && "md:mt-0 md:w-2/5 md:shrink-0"
      ]}
      data-review-card
      data-review-kind={@review.kind}
      data-review-aside={@aside && "true"}
    >
      <%!-- Row one: the cover beside what names the work — kind, title,
      author, year · medium, publisher. --%>
      <div class="flex gap-3">
        <%!-- The cover column. The cover keeps ONE size at every width (the
        desktop/aside one): the card carries the same facts on a phone as on a
        wide screen, so it should read the same there too — a
        breakpoint-dependent cover made the identical card look like two
        different components. --%>
        <div class="w-16 shrink-0" data-review-cover>
          <img
            :if={@cover_url}
            src={@cover_url}
            alt=""
            loading="lazy"
            class="w-16 rounded-lg ring-1 ring-slate-200 dark:ring-slate-700"
          />
          <span
            :if={!@cover_url}
            aria-hidden="true"
            class="flex aspect-[2/3] w-16 items-center justify-center rounded-lg bg-brand-50 text-2xl dark:bg-brand-900/40"
          >
            {if @review.kind == "movie", do: "🎬", else: "📖"}
          </span>
          <%!-- How thick the book is belongs to the picture of it: a small,
          centered figure right under the cover, where it costs the card no
          line of its own. Just the number — under the print cover it reads for
          itself — with the print-edition note an audiobook's count needs
          (`review_pages_label/1`) kept as the hover title. --%>
          <p
            :if={@pages}
            class="mb-0 mt-1 text-center text-xs text-slate-600 dark:text-slate-400"
            title={@pages_note}
            data-review-pages
          >{@pages}</p>
        </div>

        <%!-- No "Book review" / "Film review" caption: the cover (or the kind
        glyph standing in for it), the title and the medium already say what
        this is, and the post's own prose says it again — the label was a line
        of the card spent on nothing. The kind still reaches machines through
        the JSON-LD and the agent-format siblings. --%>
        <div class="min-w-0" data-review-identity>
          <%!-- A title runs to two lines at most (`line-clamp-2`): the long
          subtitled ones a catalogue hands back ("… — Roman. Mit einem Nachwort
          des Autors") would otherwise push the whole card several lines taller
          than the cover beside it. The full title stays in the hover title and
          in every agent-format sibling. --%>
          <p
            class="mb-0 line-clamp-2 font-semibold text-slate-900 dark:text-slate-100"
            title={@review.title}
            data-review-title
          >{@review.title}</p>
          <%!-- Creator on the line DIRECTLY under the title (`mb-0` up there
          kills the legacy 15px paragraph margin, which used to open a blank
          line between a work and who wrote it), year · medium below it, the
          publisher below that — at every width, not only in the narrow aside.
          That reading was the aside's, and it is what the card shows
          everywhere now: one card, one layout, so a phone and a wide screen
          never disagree about what a review looks like. All three are lines of
          ONE paragraph, so they read as one tight identity block instead of
          drifting apart on that same margin. The creator is named ("by: …"):
          between a title above and a publisher below, a bare name is the one
          line that doesn't say what it is. It is cut at two lines like the
          title (a catalogue "creator" can be a whole list of authors, editors
          and translators); `line-clamp-2` sets its own `display`, so it needs
          no `block` beside it — and must not get one, or the two display
          utilities would fight. --%>
          <p
            :if={@review.creator || @review.year || @review.medium || @review.publisher}
            class="mb-0 text-sm text-slate-600 dark:text-slate-400"
          ><span
              :if={@review.creator}
              class="line-clamp-2"
              title={@review.creator}
              data-review-creator
            >{gettext("by:")} {@review.creator}</span><span
              :if={review_year_medium(@review) != "" || @duration}
              class={@review.creator && "block"}
              data-review-meta
            >{@review.year}{if @review.year && (review_medium_label(@review.medium) || @duration),
              do: " · "}<.review_medium review={@review} /></span><span
              :if={@review.publisher}
              class="block"
              data-review-publisher
            >{gettext("Publisher:")} {@review.publisher}</span></p>
          <%!-- The ISBN closes the identity block, one size down: it names this
          exact edition, but it is a catalogue number nobody reads at a glance,
          so it belongs with the facts about the work rather than on a line of
          its own weight further down. `whitespace-nowrap` keeps the number
          whole — its hyphens are line-break opportunities, so it would
          otherwise split mid-number; the space after "ISBN" stays a break
          opportunity, so a narrow aside wraps the label instead of overflowing
          the column. --%>
          <p
            :if={@isbn}
            class="mb-0 mt-1 text-xs text-slate-600 dark:text-slate-400"
            data-review-isbn
          >
            ISBN <span class="whitespace-nowrap">{@isbn}</span>
          </p>
        </div>
      </div>

      <%!-- Row two, one full-width line under the cover: where to go next. The
      facts about the edition all read beside the cover now, so this row is the
      outbound links alone — the book's own Open Library page first, then the
      store link (Amazon / IMDb), dot-separated, both plain brand links. Full
      width because the line is longer than the column beside the cover and
      either half may be missing. The Open Library link shows only when a cover
      is actually rendered, because it also credits the source of that quoted
      image (§ 63 UrhG) — the courtesy link back Open Library asks for. --%>
      <p
        :if={@external_url || @cover_url}
        class="mb-0 mt-2 text-sm text-slate-600 dark:text-slate-400"
        data-review-links
      >
        <.link
          :if={@cover_url}
          href={@cover_source_url}
          target="_blank"
          rel="nofollow noopener noreferrer"
          class={review_link_class()}
        >Open Library</.link><span :if={@cover_url && @external_url}> · </span><a
          :if={@external_url}
          href={@external_url}
          target="_blank"
          rel="nofollow noopener noreferrer"
          class={review_link_class()}
        >{review_link_label(@review.kind)}</a>
      </p>
    </div>
    """
  end

  # The medium word on the identity block's year · medium line, with an
  # audiobook's running time in parentheses right behind it ("Audiobook (7 h
  # 20 min)") — the length answers the medium, so it reads there instead of
  # costing the card a line of its own. An audiobook links the WORD to Audible
  # (PostReview.audible_url/1 — a title search, since Audible keys by its own
  # ASIN, not our print ISBN); every other medium stays plain text, and the
  # parenthetical stays outside the link either way. Rendered as the medium's
  # own inline piece so only the word is the link, not the whole year · medium
  # line. Nothing at all for a review with neither medium nor running time.
  attr(:review, PostReview, required: true)

  defp review_medium(assigns) do
    assigns =
      assigns
      |> assign(:label, review_medium_label(assigns.review.medium))
      |> assign(:duration, review_duration_label(assigns.review))
      |> assign(:audible_url, PostReview.audible_url(assigns.review))

    ~H"""
    <%= cond do %>
      <% @label && @audible_url -> %>
        <.link
          href={@audible_url}
          target="_blank"
          rel="nofollow noopener noreferrer"
          class={review_link_class()}
        >{@label}</.link> <span :if={@duration} class="whitespace-nowrap">({@duration})</span>
      <% @label -> %>
        {@label} <span :if={@duration} class="whitespace-nowrap">({@duration})</span>
      <% @duration -> %>
        {@duration}
      <% true -> %>
    <% end %>
    """
  end

  # One style for every outbound link on a review card — the medium word, the
  # Open Library page, the store link — so they read as one consistent link
  # (brand blue, no underline) instead of a mix.
  defp review_link_class,
    do: "text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"

  # The credited source of a fetched cover: the book's own Open Library page
  # when we have the ISBN it was fetched by, else the site itself.
  defp cover_source_url(%PostReview{kind: "book", identifier: isbn}) when is_binary(isbn),
    do: "https://openlibrary.org/isbn/#{isbn}"

  defp cover_source_url(%PostReview{}), do: "https://openlibrary.org"

  defp review_external_url(%PostReview{kind: "book"} = review), do: PostReview.amazon_url(review)
  defp review_external_url(%PostReview{kind: "movie"} = review), do: PostReview.imdb_url(review)
  defp review_external_url(%PostReview{}), do: nil

  @doc """
  The post's review sidecar as one compact HTML paragraph (an escaped raw
  string, `""` when the post carries none) — appended to the rendered body
  wherever the post leaves the site as plain HTML: the federated
  ActivityPub Note (`VutuvWeb.Fediverse.Docs`) and the RSS items
  (`VutuvWeb.Feeds`). Remote software knows nothing of review cards, so the
  facts ride inside the content itself.
  """
  def review_content_html(%{review: %PostReview{} = review}) do
    {glyph, label} =
      case review.kind do
        "movie" -> {"🎬", gettext("Film review")}
        _book -> {"📖", gettext("Book review")}
      end

    isbn =
      if review.kind == "book" and review.identifier,
        do: "ISBN #{Isbn.format(review.identifier)}"

    details =
      [
        review.creator,
        review.year,
        review_medium_label(review.medium),
        review.publisher,
        review_pages_label(review),
        review_duration_label(review),
        isbn
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join("", &" · #{esc(&1)}")

    link = PostReview.amazon_url(review) || PostReview.imdb_url(review)

    title =
      if link,
        do: ~s(<a href="#{esc(link)}" rel="nofollow noopener">#{esc(review.title)}</a>),
        else: esc(review.title)

    "<p>#{glyph} #{esc(label)}: #{title}#{details}</p>"
  end

  def review_content_html(_post), do: ""

  defp esc(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  @doc """
  The display label of a review medium (how the reviewer consumed the work),
  nil for nil — shared by the review card, the composer's select and the
  agent docs, so the wording cannot drift.
  """
  def review_medium_label(nil), do: nil
  def review_medium_label("print"), do: gettext("Printed book")
  def review_medium_label("ebook"), do: gettext("E-book")
  def review_medium_label("audiobook"), do: gettext("Audiobook")
  def review_medium_label("cinema"), do: gettext("Cinema")
  def review_medium_label("streaming"), do: gettext("Streaming")
  def review_medium_label("disc"), do: gettext("DVD/Blu-ray")
  def review_medium_label(_other), do: nil

  @doc """
  The page count of the reviewed book as a reader-facing label ("384 pages"),
  nil when no catalogue reported one — shared by the review card, the agent
  docs and the federated/RSS rendering. The number goes through
  `delimited_count/1` like every other figure, so it needs its own
  placeholder: `ngettext/4` binds `%{count}` to the raw integer.

  On an **audiobook** the count is marked as the print edition's ("190 pages
  (print edition)"): the audiobook has no pages, and the number answers the
  question a reader is really asking — how long is this book — but it must
  not read as a fact about the recording.

  Takes the review struct **or** the agent-doc entry that mirrors it (same
  keys), so card and machine formats cannot word this differently.
  """
  def review_pages_label(review) do
    case review_pages_short(review) do
      nil ->
        nil

      label ->
        if Map.get(review, :medium) == "audiobook",
          do: label <> " " <> gettext("(print edition)"),
          else: label
    end
  end

  # The bare page count ("384 pages"), without the audiobook's print-edition
  # marker — what the card prints under the cover, where the picture of the
  # printed book already says which edition the number belongs to and the
  # marker would only cost a second line. `review_pages_label/1` above is the
  # spelled-out form for everywhere the cover isn't there to say it.
  defp review_pages_short(%{pages: pages}) when is_integer(pages) and pages > 0 do
    ngettext("%{formatted} page", "%{formatted} pages", pages, formatted: delimited_count(pages))
  end

  defp review_pages_short(_other), do: nil

  # The spelled-out page count for the card's hover title, nil when it says
  # nothing the short line under the cover doesn't already say (every medium
  # but an audiobook).
  defp review_pages_note(review) do
    short = review_pages_short(review)
    full = review_pages_label(review)

    if short && full != short, do: full
  end

  @doc """
  An audiobook's running time as a reader-facing label ("7 h 20 min",
  German "7 Std. 20 Min."), nil when no catalogue stated one. Whole minutes
  in, hours and minutes out — the form every audiobook shop prints.

  A time read from **another** audio edition of the same work (the review
  carries the print ISBN, so `duration_isbn` names where it came from) is
  prefixed "approx." — the editions the catalogue lists agreed on it, but it
  is not this pressing's stated length and must not read as one.
  """
  def review_duration_label(%{duration_minutes: total} = review)
      when is_integer(total) and total > 0 do
    label =
      case {div(total, 60), rem(total, 60)} do
        {0, minutes} -> gettext("%{minutes} min", minutes: minutes)
        {hours, 0} -> gettext("%{hours} h", hours: hours)
        {hours, minutes} -> gettext("%{hours} h %{minutes} min", hours: hours, minutes: minutes)
      end

    case Map.get(review, :duration_isbn) do
      nil -> label
      _other_edition -> gettext("approx. %{duration}", duration: label)
    end
  end

  def review_duration_label(_other), do: nil

  # The outbound link reads as the bare store/database name — a proper noun,
  # identical in every locale, so no gettext.
  defp review_link_label("movie"), do: "IMDb"
  defp review_link_label(_kind), do: "Amazon"

  # The ISBN as the card prints it (hyphenated), nil for a film or a book
  # whose reviewer typed no ISBN.
  defp review_isbn(%PostReview{kind: "book", identifier: isbn}) when is_binary(isbn),
    do: Isbn.format(isbn)

  defp review_isbn(%PostReview{}), do: nil

  # The year · medium half of the details line (everything but the creator),
  # so the card can drop it onto its own line below the author's.
  defp review_year_medium(%PostReview{} = review) do
    [review.year, review_medium_label(review.medium)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  # The link screenshot image, shared by the preview and full layouts — both
  # float it beside the body. A decorative duplicate of the body's autolinked
  # URL — `aria-hidden` + `tabindex=-1` so assistive tech and the tab order keep
  # the one link in the prose — opening the page in a new tab. `class` positions
  # it and sets the width.
  attr(:screenshot, :any, required: true)
  attr(:pixelated_url, :any, default: nil, doc: "set while the AI scan holds the capture")
  attr(:class, :string, default: nil)

  defp link_screenshot_image(assigns) do
    ~H"""
    <.link
      href={@screenshot.url}
      target="_blank"
      rel="noopener"
      aria-hidden="true"
      tabindex="-1"
      data-link-screenshot
      class={@class}
    >
      <span :if={@pixelated_url} class="relative block" data-screenshot-pixelated>
        <img
          src={@pixelated_url}
          width="400"
          height="264"
          loading="lazy"
          alt=""
          class="aspect-[400/264] w-full rounded-lg object-cover ring-1 ring-slate-200 dark:ring-slate-800"
        />
        <.checking_badge />
      </span>
      <img
        :if={!@pixelated_url}
        src={Vutuv.Screenshot.url({@screenshot.screenshot, @screenshot}, :thumb)}
        width="400"
        height="264"
        loading="lazy"
        alt=""
        class="aspect-[400/264] w-full rounded-lg object-cover ring-1 ring-slate-200 dark:ring-slate-800"
      />
    </.link>
    """
  end

  @doc """
  Author-facing label for a post-denial wildcard — the one wording for "who
  can't see this", shared by the composer's audience sheet and the permalink
  page's audience summary (`VutuvWeb.PostHTML.denial_labels/1`).
  """
  def wildcard_label("everyone"), do: gettext("everyone else")
  def wildcard_label("non_connections"), do: gettext("people who aren't your connections")
  def wildcard_label("non_followers"), do: gettext("people who don't follow you")
  def wildcard_label("non_followees"), do: gettext("people you don't follow")
  def wildcard_label("logged_out"), do: gettext("logged-out visitors")
  def wildcard_label(other) when is_binary(other), do: other

  @doc """
  The action bar markup (like / reply / repost / bookmark with live counters),
  shared by both renderings of a post card's bar so they can never drift:
  `VutuvWeb.PostLive.ActionsComponent` (LiveView hosts, `target` = its `@myself`)
  and the standalone `VutuvWeb.PostLive.Actions` LiveView (dead pages, no
  `target` → the events reach the LiveView itself). Renders nothing once
  `engagement` is nil (a deleted post empties the bar).
  """
  attr(:id, :string, required: true, doc: ~s|button-id base, e.g. "post-actions-post-<id>"|)
  attr(:post_id, :any, required: true)
  attr(:engagement, :any, default: nil)

  attr(:viewer_id, :any,
    default: nil,
    doc: "the viewer's user id (nil when logged out), to detect their own post"
  )

  attr(:acting_as_id, :any,
    default: nil,
    doc: "the page this bar acts as, when the viewer is speaking as one (issue #1336)"
  )

  attr(:target, :any,
    default: nil,
    doc: "phx-target: the LiveComponent's @myself on a host page, nil on a dead page"
  )

  attr(:reset, :integer,
    default: 0,
    doc:
      "bumped by the bar when an act was refused; changes the controls' ids, see `control_id/3`"
  )

  def post_actions(assigns) do
    assigns =
      assigns
      |> assign(
        :own?,
        own_post?(assigns)
      )
      # One number per act, vutuv's own and the other networks' together
      # (`Posts.shown_counts/1`); the panel below breaks it back down.
      |> assign(:counts, assigns.engagement && Posts.shown_counts(assigns.engagement))

    ~H"""
    <%!-- justify-between spreads the four controls across the column's full
          width (X-style); -mx-2 cancels the outer buttons' px-2 so the first
          and last glyphs line up with the column edges. --%>
    <div
      :if={@engagement}
      class="-mx-2 mt-3 flex items-center justify-between gap-2 text-slate-600 dark:text-slate-400"
    >
      <.like_control
        id={control_id(@id, "like", @reset)}
        target={@target}
        own?={@own?}
        liked?={@engagement.liked?}
        count={@counts.likes}
      />

      <.reply_link
        id={"#{@id}-reply"}
        post_id={@post_id}
        count={@counts.replies}
        disabled={@engagement.restricted?}
      />

      <.action_button
        id={control_id(@id, "repost", @reset)}
        target={@target}
        kind="repost"
        active?={@engagement.reposted?}
        count={@counts.reposts}
        on_label={gettext("Undo repost")}
        off_label={gettext("Repost")}
        active_class="text-brand-600 dark:text-brand-300"
        disabled={@engagement.restricted?}
        disabled_title={gettext("Only public posts can be reposted.")}
      >
        <:icon><.icon_repost /></:icon>
      </.action_button>

      <.action_button
        id={control_id(@id, "bookmark", @reset)}
        target={@target}
        kind="bookmark"
        active?={@engagement.bookmarked?}
        count={@engagement.bookmarks}
        on_label={gettext("Remove bookmark")}
        off_label={gettext("Bookmark")}
        active_class="text-brand-600 dark:text-brand-300"
        filled?
      >
        <:icon><.icon_bookmark filled?={@engagement.bookmarked?} /></:icon>
      </.action_button>
    </div>

    <.fediverse_details
      :if={@engagement}
      likes={Map.get(@engagement, :fediverse_likes) || 0}
      reposts={Map.get(@engagement, :fediverse_reposts) || 0}
      replies={Map.get(@engagement, :fediverse_replies) || 0}
      actors={Map.get(@engagement, :fediverse_reaction_actors, [])}
    />
    """
  end

  # What other networks did with this post (issues #1068 and #1069), now folded
  # into the counters above and explained here.
  #
  # The card used to print two sets of figures: the vutuv counters in the
  # buttons and a permanent "from other networks" line under them. Correct, and
  # it read as bookkeeping — a reader wanting to know how a post did had to add
  # two columns in their head, and a post with one boost carried a whole line
  # about it. So a like is a like and a repost is a repost whichever world it
  # came from (`Vutuv.Posts.shown_counts/1`), and the split moves in here, one
  # tap away.
  #
  # Nothing is lost by folding, which is what this panel is for: it breaks the
  # totals back down per verb, **names** the accounts that reacted (one chip
  # each, linking out to the account — there is no vutuv profile behind it) and
  # says in so many words that the numbers above already include them. A bare
  # "1 reaction from other networks" was a rumour; a chip is the whole stored
  # row, the account address and the verb. Public, like the counts always were:
  # both a favourite and a re-share are acts those networks publish under the
  # actor's own name, and the reply cards below already name their authors the
  # same way. A remote server can still only inflate figures that this panel
  # labels as its own.
  #
  # Collapsed by default (`<details>`, no JS), so the common reader sees three
  # calm numbers; renders nothing at all while every remote figure is zero, so
  # a post nobody out there touched stays clean. The reply figure counts
  # **public** replies only, so a note addressed to the member alone (issue
  # #1071) never moves a number a stranger can read.
  attr(:likes, :integer, required: true)
  attr(:reposts, :integer, required: true)
  attr(:replies, :integer, required: true)
  attr(:actors, :list, required: true, doc: "the newest few reaction rows, JSON-decoded")

  defp fediverse_details(%{likes: likes, reposts: reposts, replies: replies} = assigns)
       when likes > 0 or reposts > 0 or replies > 0 do
    reactions = likes + reposts
    shown = shown_reaction_actors(assigns.actors, reactions)

    assigns =
      assigns
      |> assign(:reactions, reactions)
      |> assign(:total, reactions + replies)
      |> assign(:shown, shown)
      |> assign(:more, reactions - length(shown))

    ~H"""
    <details
      class="group mt-2 border-t border-slate-100 pt-1 text-sm text-slate-600 dark:border-slate-800 dark:text-slate-400"
      data-fediverse-details
      data-fediverse-reactions={@reactions}
      data-fediverse-replies={@replies}
    >
      <%!-- min-h-10: a finger-sized target, since this is the one control on
            the card a phone reader is meant to open. --%>
      <summary class={[
        "-mx-2 flex min-h-10 cursor-pointer list-none items-center gap-2 rounded-lg px-2",
        "hover:bg-slate-100 dark:hover:bg-slate-800",
        "[&::-webkit-details-marker]:hidden"
      ]}>
        <span aria-hidden="true">🌐</span>
        <span>{gettext("From other networks")}</span>
        <%!-- slate-200/700, a step off the row's own hover tint, so the pill
              stays a pill while the summary is hovered or open. --%>
        <span class="rounded-full bg-slate-200 px-1.5 text-xs font-semibold tabular-nums dark:bg-slate-700">
          {compact_count(@total)}
        </span>
        <svg
          class="ml-auto h-4 w-4 shrink-0 transition-transform group-open:rotate-180"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          viewBox="0 0 24 24"
          aria-hidden="true"
        >
          <path stroke-linecap="round" stroke-linejoin="round" d="m19 9-7 7-7-7" />
        </svg>
      </summary>

      <div class="space-y-2 px-2 pb-2 pt-1">
        <%!-- The split, in the same order and with the same glyphs as the
              buttons above, so each figure is obviously part of one of them. --%>
        <p class="flex flex-wrap items-center gap-x-3 gap-y-1">
          <span :if={@likes > 0} class="inline-flex items-center gap-1" data-fediverse-likes={@likes}>
            <.icon_heart filled?={false} class="h-4 w-4 shrink-0" />{like_phrase(@likes)}
          </span>
          <span
            :if={@replies > 0}
            class="inline-flex items-center gap-1"
            data-fediverse-reply-count={@replies}
          >
            <.icon_reply class="h-4 w-4 shrink-0" />{reply_phrase(@replies)}
          </span>
          <span
            :if={@reposts > 0}
            class="inline-flex items-center gap-1"
            data-fediverse-reposts={@reposts}
          >
            <.icon_repost class="h-4 w-4 shrink-0" />{repost_phrase(@reposts)}
          </span>
        </p>

        <p :if={@shown != []} class="flex flex-wrap items-center gap-x-2 gap-y-1">
          <%!-- A chip is somebody the reader may well want to know more about —
                that is the whole point of naming them — so it goes wherever the
                handle on a remote card goes (`remote_actor_destination/2`): to
                their page here when we know them, out to their own server when
                we do not. Only the destination differs; the chip is one. --%>
          <.link
            :for={actor <- @shown}
            {remote_actor_destination(actor.account_id, actor.uri)}
            data-fediverse-reaction={actor.kind}
            data-remote-account={actor.account_id}
            title={reaction_title(actor)}
            class="inline-flex min-h-10 max-w-full items-center gap-1 rounded-full bg-slate-100 px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-200 hover:text-brand-700 dark:bg-slate-800 dark:text-slate-300 dark:hover:bg-slate-700 dark:hover:text-brand-300"
          >
            <%!-- The same two glyphs the vutuv action bar above uses for the
                  same two acts, so "shared" and "favourited" read identically
                  whichever world they came from. --%>
            <.icon_repost :if={actor.kind == "announce"} class="h-3.5 w-3.5 shrink-0" />
            <.icon_heart
              :if={actor.kind != "announce"}
              filled?={false}
              class="h-3.5 w-3.5 shrink-0"
            />
            <span class="sr-only">{reaction_title(actor)}</span>
            <span aria-hidden="true" class="break-all">{actor.handle}</span>
          </.link>

          <span :if={@more > 0} data-fediverse-reactions-more={@more}>
            {gettext("+%{count} more", count: compact_count(@more))}
          </span>
        </p>

        <p class="text-xs">{gettext("Already counted in the numbers above.")}</p>
      </div>
    </details>
    """
  end

  defp fediverse_details(assigns), do: ~H""

  # The rows the SQL cap handed us (`Vutuv.Posts.engagement_count_select/1`
  # fetches a few more than a card should show), normalised out of their
  # JSON string keys. Showing every fetched row when the total fits keeps the
  # common "one boost" case whole; past that one slot goes to the "+N" tail so
  # the count and the chips always add up.
  defp shown_reaction_actors(actors, total) when is_list(actors) do
    actors = Enum.map(actors, &reaction_actor/1)

    if total > length(actors), do: Enum.take(actors, length(actors) - 1), else: actors
  end

  defp shown_reaction_actors(_actors, _total), do: []

  defp reaction_actor(%{"actor_uri" => uri} = row) do
    %{
      uri: uri,
      kind: row["kind"],
      handle: Handle.display(row["handle"], uri),
      # Whether we already know this account (issue #1162), read alongside the
      # reaction in the engagement query rather than looked up per chip.
      account_id: row["account_id"]
    }
  end

  # What the chip says to a screen reader and on hover — the sentence the glyph
  # alone cannot carry.
  defp reaction_title(%{kind: "announce", handle: handle}),
    do: gettext("%{handle} shared this", handle: handle)

  defp reaction_title(%{handle: handle}),
    do: gettext("%{handle} liked this", handle: handle)

  defp reply_phrase(count) do
    ngettext("%{formatted} reply", "%{formatted} replies", count, formatted: compact_count(count))
  end

  defp like_phrase(count) do
    ngettext("%{formatted} like", "%{formatted} likes", count, formatted: compact_count(count))
  end

  defp repost_phrase(count) do
    ngettext("%{formatted} repost", "%{formatted} reposts", count,
      formatted: compact_count(count)
    )
  end

  # Whether the acting identity is the post's own author, which is what turns
  # the heart into a plain count. While speaking as a page the actor is the
  # page, so that is the id to compare — asking about the member would offer a
  # page a live heart on its own post and then refuse the click.
  defp own_post?(%{engagement: nil}), do: false

  defp own_post?(assigns) do
    actor_id = assigns[:acting_as_id] || assigns.viewer_id
    actor_id != nil and assigns.engagement.author_id == actor_id
  end

  # The Like control: a real toggle for everyone but the author. On your OWN
  # post it is a plain, non-interactive count instead of a clickable heart —
  # a member cannot like their own post (issue #1030), so the toggle would be
  # a dead control. Same slot and id either way, so the row layout and the
  # tests that key on `#…-like` don't care which branch renders.
  attr(:id, :string, required: true)
  attr(:target, :any, default: nil)
  attr(:own?, :boolean, required: true)
  attr(:liked?, :boolean, required: true)
  attr(:count, :integer, required: true)

  defp like_control(assigns) do
    ~H"""
    <.action_button
      :if={!@own?}
      id={@id}
      target={@target}
      kind="like"
      active?={@liked?}
      count={@count}
      on_label={gettext("Unlike")}
      off_label={gettext("Like")}
      active_class="text-accent"
      filled?
    >
      <:icon><.icon_heart filled?={@liked?} /></:icon>
    </.action_button>
    <span
      :if={@own?}
      id={@id}
      title={gettext("You can't like your own post.")}
      aria-label={gettext("Likes")}
      class="inline-flex cursor-default items-center gap-1.5 rounded-lg px-2 py-1 text-sm text-slate-600 dark:text-slate-400"
    >
      <.icon_heart filled?={false} />
      <.count_pill count={@count} kind="like" />
    </span>
    """
  end

  # The reply control is a navigation, not a toggle: it leads to the reply page
  # (which requires login itself). Restricted posts cannot be answered,
  # mirroring the disabled repost button. rel="nofollow" because for a crawler
  # every reply URL is just a 302 to /login — without it, every public post
  # card feeds one useless URL into the crawl frontier, which piled up as
  # "blocked by robots.txt" noise in Search Console.
  attr(:id, :string, required: true)
  attr(:post_id, :any, required: true)
  attr(:count, :integer, required: true)
  attr(:disabled, :boolean, required: true)

  defp reply_link(assigns) do
    ~H"""
    <.link
      :if={!@disabled}
      id={@id}
      href={~p"/posts/#{@post_id}/reply"}
      rel="nofollow"
      aria-label={gettext("Reply")}
      title={gettext("Reply")}
      class={[
        "inline-flex items-center gap-1.5 rounded-lg px-2 py-1 text-sm",
        "hover:bg-slate-100 dark:hover:bg-slate-800",
        # components.css colors bare `a, button` brand-600, which beats the
        # wrapper's inherited slate — so the muted color sits on the link.
        "text-slate-600 dark:text-slate-400"
      ]}
    >
      <.icon_reply />
      <.count_pill count={@count} kind="reply" />
    </.link>
    <span
      :if={@disabled}
      id={@id}
      aria-disabled="true"
      title={gettext("Only public posts can be answered.")}
      class="inline-flex cursor-not-allowed items-center gap-1.5 rounded-lg px-2 py-1 text-sm text-slate-500 opacity-40 dark:text-slate-400"
    >
      <.icon_reply />
      <.count_pill count={@count} />
    </span>
    """
  end

  attr(:id, :string, required: true)
  attr(:target, :any, default: nil)
  attr(:kind, :string, required: true)
  attr(:active?, :boolean, required: true)
  attr(:count, :integer, required: true)
  attr(:on_label, :string, required: true, doc: "what the control says while pressed")
  attr(:off_label, :string, required: true, doc: "and while not")
  attr(:active_class, :string, required: true)
  attr(:filled?, :boolean, default: false, doc: "the glyph fills while active (heart, bookmark)")
  attr(:disabled, :boolean, default: false)
  attr(:disabled_title, :string, default: nil)
  slot(:icon, required: true)

  defp action_button(assigns) do
    assigns =
      assigns
      |> assign(:label, if(assigns.active?, do: assigns.on_label, else: assigns.off_label))
      |> assign(:idle_class, @idle_action_class)

    ~H"""
    <button
      type="button"
      id={@id}
      phx-click={toggle_js(@active_class, @on_label, @off_label)}
      phx-target={@target}
      phx-value-kind={@kind}
      disabled={@disabled}
      aria-pressed={to_string(@active?)}
      aria-label={@label}
      title={if(@disabled, do: @disabled_title, else: @label)}
      data-count-steps
      data-fills-when-pressed={@filled? && "true"}
      class={[
        "inline-flex items-center gap-1.5 rounded-lg px-2 py-1 text-sm",
        @disabled && "cursor-not-allowed opacity-40",
        !@disabled && "hover:bg-slate-100 dark:hover:bg-slate-800",
        # components.css colors bare `a, button` brand-600, which beats the
        # wrapper's inherited slate — so the state color sits on the button.
        if(@active?, do: @active_class, else: @idle_class)
      ]}
    >
      {render_slot(@icon)}
      <.toggle_count count={@count} kind={@kind} active?={@active?} />
    </button>
    """
  end

  # The optimistic flip. A press used to leave the button untouched until the
  # server had written the row and pushed a diff back — one round trip, which on
  # a slow line reads as a control that does not work. So the press paints the
  # new state on the spot and *also* pushes, and the answer confirms what the
  # member already sees. LiveView's own recipe ("Syncing changes and optimistic
  # UIs"); no hook, because the JS commands are DOM-patch aware.
  #
  # **Everything it touches lives on the button itself**, and the glyph's fill
  # and which step of the count shows are derived from `aria-pressed` in CSS
  # (`[data-fills-when-pressed]` / `[data-count-steps]` in `components.css`).
  # That is not tidiness. A JS command aimed at a child leaves its stash on that
  # child, and when the refusal counter below hands morphdom a fresh button,
  # morphdom **moves the old unkeyed children into it** rather than building
  # them — so the heart stayed filled after a refused like while the button
  # around it had correctly gone back to grey (measured over CDP: the button was
  # a new node, the `<svg>` inside it the very same one). Keeping all client
  # state on the one element the counter re-keys is what makes the take-back
  # complete.
  #
  # The rule that makes it safe: **every value toggled here is a function of the
  # absolute state** (pressed / not pressed), never of the state at click time.
  # LiveView stashes each class and attribute op on the element and re-applies
  # it after every patch, and nothing ever expires it (`DOM.putSticky` /
  # `applyStickyOperations`; `deleteSticky` has no caller). An op phrased as
  # "flip whatever is there" would therefore fight the server's own correct
  # re-render for the rest of the element's life — a count stuck one too low
  # once somebody else's like arrives over PubSub. Phrased absolutely, the stash
  # and the server agree the moment the answer lands.
  #
  # What is left is the trade we took on purpose: where the server *disagrees* —
  # a refused act, a toggle from the member's other tab — the button keeps
  # showing the press until the next press or a reload.
  defp toggle_js(active_class, on_label, off_label) do
    JS.push("toggle")
    |> JS.toggle_class("#{active_class} #{@idle_action_class}")
    |> JS.toggle_attribute({"aria-pressed", "true", "false"})
    |> JS.toggle_attribute({"aria-label", on_label, off_label})
    |> JS.toggle_attribute({"title", on_label, off_label})
  end

  # Both steps of the count, pre-rendered: what it reads while the control is
  # off, and what it reads while on. The press shows the other one, which is why
  # the client never has to know that 1000 is written "1K" — `compact_count/1`
  # is locale-aware and stays on the server, where it belongs.
  #
  # The spans are keyed by the *absolute* state, not by "current" and
  # "alternative", so the stashed class op above lines up with what the server
  # renders next (see `toggle_js/4`). `data-count` marks the step the server is
  # showing, so the agent-facing marker never reads twice.
  attr(:count, :integer, required: true)
  attr(:kind, :string, required: true)
  attr(:active?, :boolean, required: true)

  defp toggle_count(assigns) do
    assigns =
      assigns
      |> assign(:off, if(assigns.active?, do: assigns.count - 1, else: assigns.count))
      |> assign(:on, if(assigns.active?, do: assigns.count, else: assigns.count + 1))

    ~H"""
    <%!-- Always mounted (invisible at zero) so an arriving first count
          doesn't shift the neighbouring buttons under the pointer. --%>
    <span
      data-count-off
      class={["font-medium tabular-nums", @off == 0 && "invisible"]}
      data-count={!@active? && @off > 0 && @kind}
    >{compact_count(@off)}</span>
    <span data-count-on class="font-medium tabular-nums" data-count={@active? && @on > 0 && @kind}>{compact_count(@on)}</span>
    """
  end

  # The shared count pill: invisible (but mounted) at zero so an arriving first
  # count doesn't shift neighbours, formatted through compact_count. `kind` is
  # the data-count token (nil omits the attribute, as the disabled reply branch
  # does).
  attr(:count, :integer, required: true)
  attr(:kind, :string, default: nil)

  defp count_pill(assigns) do
    ~H"""
    <span
      class={["font-medium tabular-nums", @count == 0 && "invisible"]}
      data-count={@kind && @count > 0 && @kind}
    >
      {compact_count(@count)}
    </span>
    """
  end
end
