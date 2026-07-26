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

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse.Note
  alias Vutuv.Isbn
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Posts
  alias Vutuv.Posts.PhotoLicense
  alias Vutuv.Posts.PostImage
  alias Vutuv.Posts.PostRemoteReply
  alias Vutuv.Posts.PostReview
  alias Vutuv.Posts.PostScreenshot
  alias Vutuv.ReviewCover

  # How many reposter faces the "Reposted by" avatar stack shows before the
  # rest collapse into a `+N` chip. Five keeps the strip to one tidy line even
  # on a phone (5 × 20px avatars, overlapped, plus the chip and the sentence).
  @repost_stack_cap 5

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

  def post_card(assigns) do
    # The reader's post-display preferences (per-breakpoint line clamp +
    # hyphenation), fed onto the body as CSS custom properties below.
    prefs = User.post_prefs(assigns.viewer)

    # A logged-in viewer (vs anonymous / a "View as public" preview, both nil),
    # bound once and reused for the acting-viewer id and the reporter test.
    viewer = assigns.viewer
    user? = match?(%User{}, viewer)

    # AI-moderation limbo (Vutuv.Moderation.ImageScans): the author and admins
    # see a pending image themselves (plus the limbo pill below); every other
    # viewer gets a neutral placecard tile instead. The post struct is patched
    # once, so every branch below (gallery, inline refs, square layout) works
    # on the filtered set.
    {shown_images, held_count} = split_gallery(assigns.post, viewer)
    post = %{assigns.post | images: shown_images}

    # The whole body is always shipped to the DOM. In :preview the CSS clamp
    # does the visual cut and the in-place expand button reveals the rest, so
    # "Read more" expands in place instead of navigating to the permalink —
    # feed and profile alike. Inline images render in place in BOTH modes
    # from the viewer-visible set (shown_images), so an unreleased picture
    # simply stays absent for strangers while the author sees it; a preview
    # body carrying inline images switches to the height-based media clamp
    # (`inline_media?` below — a line clamp cannot hold pictures or floats).
    body_html = VutuvWeb.Markdown.render_post(post.body, post.images)

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
      |> assign(:held_count, held_count)
      # The "only you can see this" banner keys on the **post-level** hold, not
      # on the individual pictures: what it announces is that the whole post is
      # being held back (`Posts.moderation_hidden?/1`), which is a fact about
      # the post. Keying it on the images would also make it disappear on a
      # viewer whose image list happens to be filtered.
      |> assign(:limbo_pill?, Posts.held_for_image_check?(post))
      # How far the AI scan has got, for the author's progress line. Counted
      # from the post's own (unfiltered) image list, so "2 of 5" means the
      # photos the author attached, not the subset this viewer can see.
      |> assign(:check_progress, Posts.image_check_progress(assigns.post))
      |> assign(:body_html, body_html)
      # The inline CSS custom properties (`--post-clamp-*` / `--post-hyphens-*`)
      # that carry the reader's preference onto the post body; nil for a default
      # / logged-out reader, so their DOM stays clean and the CSS fallbacks apply.
      |> assign(:body_style, post_body_style(prefs))
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
      # The auto link screenshot (a ready %PostScreenshot{} for an image-less
      # single-URL post, else nil) and whether the preview lays it beside the
      # text (3/4 body, 1/4 screenshot).
      |> assign(:link_screenshot, link_screenshot(post))
      |> assign(:link_screenshot_layout?, link_screenshot_layout?(post, assigns.mode))
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
      |> assign(:menu_id, "post-menu-#{entry_key}")
      # Keyed on the timeline entry like every other id here, so the same post
      # rendered twice on a page keeps unique pin controls.
      |> assign(:pin_item_id, "pin-post-#{entry_key}")
      |> assign(:unpin_item_id, "unpin-post-#{entry_key}")
      |> assign(:report_menu_id, "post-report-#{entry_key}")
      |> assign(:time_id, "post-time-#{entry_key}")
      |> assign(:body_id, "post-body-#{entry_key}")
      |> assign(:author?, Posts.author?(post, viewer))
      # Whether this post is the one its author pinned to their profile (issue
      # #1110) — read off the already-preloaded author, so it costs no query.
      # Drives the menu's Pin / Unpin label and its "replaces the other one"
      # prompt; the visible banner is the caller's `pinned?` (see the attr).
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
      |> assign(:reply_banner, reply_banner(post, assigns.show_reply_banner))
      |> assign(:reposters, repost_roster(assigns))
      |> assign(
        :edited?,
        NaiveDateTime.diff(post.updated_at, post.inserted_at) > 60
      )

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
  `<.post_thread_entry>`. Stream attrs (`id`, `phx-update`, `data-post-list`) flow
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
  The post-type filter tab bar (issue #945), a segmented control matching the
  profile's other in-card tabs. Two modes, one look:

    * pass `event` for a LiveView host (the profile) — each tab is a
      `phx-click` button firing `event` with `phx-value-type`, so it toggles
      with no reload;
    * pass `base_path` for a dead page (the `/:slug/posts` archive) — each tab
      is a plain link to `base_path` (+ `?type=`), a full navigation.

  `active` is the current filter string; the matching tab reads as selected.
  """
  attr(:active, :string, required: true)
  attr(:event, :string, default: nil, doc: "phx-click event name → button mode")
  attr(:base_path, :string, default: nil, doc: "archive base path → link mode")
  attr(:rest, :global, doc: "container attrs, e.g. an id for tests")

  def post_filter_tabs(assigns) do
    ~H"""
    <div
      class="mb-4 flex gap-1 overflow-x-auto rounded-lg bg-slate-100 p-1 text-sm dark:bg-slate-800"
      {@rest}
    >
      <%= for {value, label} <- post_filter_options() do %>
        <button
          :if={@event}
          type="button"
          phx-click={@event}
          phx-value-type={value}
          data-post-filter-tab={value}
          aria-pressed={to_string(@active == value)}
          class={post_filter_tab_class(@active == value)}
        >
          {label}
        </button>
        <.link
          :if={!@event}
          href={post_filter_link(@base_path, value)}
          data-post-filter-tab={value}
          aria-current={@active == value && "page"}
          class={post_filter_tab_class(@active == value)}
        >
          {label}
        </.link>
      <% end %>
    </div>
    """
  end

  # The active tab reads as a raised white pill, the rest as quiet muted text —
  # the same treatment as the profile's Certificates & licenses tabs.
  defp post_filter_tab_class(true),
    do:
      "whitespace-nowrap rounded-md bg-white px-3 py-1 font-semibold text-brand-700 shadow-sm dark:bg-slate-900 dark:text-brand-100"

  defp post_filter_tab_class(false),
    do:
      "whitespace-nowrap rounded-md px-3 py-1 font-medium text-slate-600 hover:text-slate-900 dark:text-slate-400 dark:hover:text-slate-100"

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

  attr(:reposted_by, :any, default: nil)
  attr(:reposters, :any, default: nil)
  attr(:entry_id, :string, default: nil)
  attr(:surface, :atom, default: :flat, values: [:card, :flat])
  attr(:conn_or_socket, :any, required: true)

  attr(:nest_parent, :boolean,
    default: true,
    doc:
      "nest a reply's parent post inline. false where the parent is already on " <>
        "the page (the permalink thread), so the row is just the flat card"
  )

  def post_thread_entry(assigns) do
    # An explicit [] means "collapsed, no ancestors" (a root/standalone) and must
    # not fall back; only a missing (nil) list falls back to the one-level parent.
    ancestors = assigns.ancestors || one_level_ancestors(assigns.post, assigns.nest_parent)
    assigns = assign(assigns, :ancestors, ancestors)
    assigns = assign(assigns, :roots, thread_entry_roots(assigns))

    ~H"""
    <%= if @ancestors == [] do %>
      <.post_card
        post={@post}
        viewer={@viewer}
        viewer_follow={@viewer_follow}
        engagement={@engagement}
        reposted_by={@reposted_by}
        reposters={@reposters}
        entry_id={@entry_id}
        surface={@surface}
        conn_or_socket={@conn_or_socket}
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
          entry_id: "#{leaf_key}-parent-#{post.id}"
        }
      end)

    leaf = %{
      post: assigns.post,
      engagement: assigns.engagement,
      viewer_follow: assigns.viewer_follow,
      reposted_by: assigns.reposted_by,
      reposters: assigns.reposters,
      entry_id: assigns.entry_id
    }

    (ancestors ++ [leaf]) |> Posts.thread_forest() |> banner_on_roots()
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
        <%!-- A node is either a vutuv post or a reply from another network
        (issue #1069), which sits among them as an ordinary sibling in time
        order and wears its own skin. --%>
        <%= if Map.has_key?(node, :note) do %>
          <.remote_reply_card note={node.note} owner?={node.owner?} viewer={@viewer} />
        <% else %>
          <.post_card
            post={node.post}
            viewer={@viewer}
            viewer_follow={node.viewer_follow}
            engagement={node.engagement}
            reposted_by={node.reposted_by}
            reposters={node.reposters}
            entry_id={node.entry_id}
            surface={@surface}
            conn_or_socket={@conn_or_socket}
            mode={Map.get(node, :mode, :preview)}
            show_reply_banner={reply_banner?(node, @connected?, @indent?, first?)}
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
    * a **dashed** left rail down the body, against the solid connector rail the
      vutuv cards hang from.
    * the author's name as plain text (there is no vutuv profile to link to)
      beside their `@handle@host`, which links out to the account.
    * **no action bar.** Liking, reposting or bookmarking a note that lives on
      someone else's server is not a thing that exists, so the row is absent
      rather than dead. What is there instead is where it came from, a link to
      the original, and the takedown controls.

  The body is escaped **plain text** (`Vutuv.RemoteHtml` reduced it at the
  inbox), rendered with `whitespace-pre-line` and deliberately *not* run through
  `VutuvWeb.Markdown`: a stranger's text must not be able to mint links, least
  of all `@mention` links into local profiles. The "view the original" link
  carries the reader on when they want the real thing.

  A note its author put behind a content warning renders the warning as a closed
  lid and reveals the text on a click, which is the one thing that author asked
  for.

  Rendered only inside `VutuvWeb.PostLive.Thread`, so the takedown controls are
  plain `phx-click` events on that LiveView.
  """
  attr(:note, :map, required: true, doc: "a Vutuv.Fediverse.Note")

  attr(:owner?, :boolean,
    default: false,
    doc: "whether the viewer is the member whose post this answers (they may remove it)"
  )

  attr(:viewer, :any, default: nil, doc: "the logged-in member, or nil")

  def remote_reply_card(assigns) do
    note = assigns.note

    assigns =
      assigns
      |> assign(:author, note.display_name || Note.display_handle(note))
      |> assign(:handle, Note.display_handle(note))
      |> assign(:host, Note.host(note.actor_uri))
      |> assign(:origin, Note.origin(note))
      |> assign(:initials, name_initials(note.display_name || note.handle))
      |> assign(:public?, Note.public?(note))
      |> assign(:warned?, Note.warned?(note))
      # Only a public reply can be answered (issue #1070): a private one would
      # mean publishing half of an exchange its author asked to keep to one
      # person, so v1 does not offer it at all.
      |> assign(:can_reply?, not is_nil(assigns.viewer) and Note.public?(note))

    ~H"""
    <article data-fediverse-reply={@note.id} data-audience={@note.audience}>
      <div class="flex items-start gap-3">
        <span class="relative shrink-0">
          <span
            data-remote-avatar
            aria-hidden="true"
            class="inline-flex h-9 w-9 select-none items-center justify-center rounded-full bg-slate-200 text-xs font-semibold text-slate-600 dark:bg-slate-700 dark:text-slate-300"
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

        <div class="min-w-0 flex-1">
          <div class="flex items-start gap-2">
            <div class="flex min-w-0 flex-1 flex-wrap items-baseline gap-x-2">
              <span class="font-semibold text-slate-900 dark:text-white">{@author}</span>
              <span class="text-xs text-slate-600 dark:text-slate-400">
                <a
                  href={@note.actor_uri}
                  target="_blank"
                  rel="nofollow noopener noreferrer"
                  class="hover:text-brand-700 dark:hover:text-brand-300"
                >{@handle}</a>
                · <.post_time at={@note.received_at} />
              </span>
            </div>

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
          </div>

          <%!-- A reply addressed to the member alone (issue #1071). The lock is
          the same glyph a restricted post wears, so "not everybody sees this"
          reads the same way across the app — and the member must know it before
          they answer as if the world were watching. --%>
          <p
            :if={!@public?}
            data-remote-private
            class="mb-0 mt-0.5 text-xs font-medium text-slate-600 dark:text-slate-400"
          >
            <span aria-hidden="true">🔒</span> {gettext("Sent to you only, visible to nobody else")}
          </p>

          <div class="mt-1.5 border-l-2 border-dashed border-slate-300 pl-3 dark:border-slate-600">
            <%= if @warned? do %>
              <details data-remote-warning class="group">
                <summary class="cursor-pointer list-none text-sm font-medium text-slate-700 dark:text-slate-300">
                  <span aria-hidden="true">⚠</span> {@note.summary}
                  <span class="ml-1 text-xs font-normal text-brand-600 group-open:hidden dark:text-brand-400">
                    {gettext("Show")}
                  </span>
                </summary>
                <p class="mb-0 mt-1.5 whitespace-pre-line text-sm text-slate-700 dark:text-slate-300">
                  {@note.content_text}
                </p>
              </details>
            <% else %>
              <p class="mb-0 whitespace-pre-line text-sm text-slate-700 dark:text-slate-300">
                {@note.content_text}
              </p>
            <% end %>
          </div>

          <p class="mb-0 mt-1.5 text-xs text-slate-600 dark:text-slate-400">
            {gettext("From another network")}<span :if={@host}> · {@host}</span> ·
            <a
              href={@origin}
              target="_blank"
              rel="nofollow noopener noreferrer"
              class="font-medium text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
            >{gettext("View the original")}</a>
            <%!-- Answering is the one action on a remote reply that exists, so it
            sits here in the open beside where the reply came from. The card still
            has no action bar: liking or resharing something on somebody else's
            server is not a thing, and an absent row still beats a dead one. Shown
            to every signed-in member on a public reply — the page behind it is
            what explains a member who does not federate why they cannot send
            (issue #1070). --%>
            <span :if={@can_reply?}>
              ·
              <.link
                navigate={~p"/system/fediverse/reply/#{@note.id}"}
                data-remote-reply-link={@note.id}
                class="font-medium text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
              >{gettext("Reply")}</.link>
            </span>
          </p>
        </div>
      </div>
    </article>
    """
  end

  # A card names the post it answers only when its position alone does not say
  # it. While the thread still indents, the nesting says it. Past
  # @thread_indent_cap every card shares its parent's column, so only the
  # *first* answer — the one rendered directly below its parent — reads
  # unambiguously and every later sibling (which follows the previous branch's
  # whole subtree) gets its banner back. A forest root keeps it either way: its
  # parent is off the page.
  defp reply_banner?(node, connected?, indent?, first?) do
    Map.get(node, :show_reply_banner, false) or (connected? and not indent? and not first?)
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

  attr(:conn_or_socket, :any, required: true)

  def thread_conversation(assigns) do
    top_id = with %{id: id} <- List.first(assigns.posts), do: id
    assigns = assign(assigns, :roots, conversation_nodes(assigns.posts, top_id, assigns))

    ~H"""
    <.thread_chain nodes={@roots} viewer={@viewer} surface={:flat} conn_or_socket={@conn_or_socket} />
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
  attr(:conn_or_socket, :any, required: true)

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
        focus?: focus?,
        scroll?: assigns.auto_scroll? and focus? and post.id != top_id
      }
    end)
    |> Posts.thread_forest()
    |> banner_on_roots()
    |> weave_remote_replies(assigns[:remote_replies] || %{}, assigns.viewer)
  end

  # Hangs the replies written on other networks (issue #1069) under the posts
  # they answer, merged into that post's own answers **in time order** rather
  # than parked in a block below them. They are part of the conversation, so
  # they read as part of it; what marks them out is the card, not a ghetto.
  #
  # `remote_replies` is `Vutuv.Fediverse.list_notes/2`'s per-post map, already
  # viewer-scoped — a reply addressed to the member alone never reaches anybody
  # else's render.
  defp weave_remote_replies(nodes, remote, _viewer) when remote == %{}, do: nodes

  defp weave_remote_replies(nodes, remote, viewer) do
    Enum.map(nodes, fn node ->
      children =
        node.children
        |> weave_remote_replies(remote, viewer)
        |> merge_remote_nodes(Map.get(remote, node.post.id, []), node.post, viewer)

      %{node | children: children}
    end)
  end

  defp merge_remote_nodes(children, [], _post, _viewer), do: children

  defp merge_remote_nodes(children, notes, post, viewer) do
    owner? = match?(%User{}, viewer) and viewer.id == post.user_id

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

  @doc """
  A compact, read-only, linked preview of one post — the shared "referenced post"
  rendering. Its home is the notification page's quoted post. Read-only on
  purpose (no action bar, no live component), so a 50-row notification page stays
  cheap. (The feed/profile thread used to nest the parent through this too, but
  now renders it as a full `<.post_card>` so every element of a thread keeps its
  own action bar.)

  Renders the author (linked avatar + name → profile, `@handle` · time) and a
  clamped excerpt that links to the post permalink. `text` is the already-prepared
  excerpt: the notification page pre-clamps to three lines server-side (its own
  visibility rules must strip a denied body) and passes
  `clamp="line-clamp-3 whitespace-pre-line"` + `truncated?`. `label` is the
  optional uppercase caption that tells a reply notification's two quotes apart
  ("Your post" / "Reply"); the global `rest` carries the
  `data-post-preview` / `data-reply-preview` hooks onto the excerpt link (the
  element that owns the permalink).
  """
  attr(:post, :any, required: true, doc: "preloaded %Vutuv.Posts.Post{} with :user")
  attr(:time_id, :string, required: true)
  attr(:text, :string, required: true)
  attr(:truncated?, :boolean, default: false)
  attr(:clamp, :string, default: "truncate")
  attr(:label, :any, default: nil)
  attr(:class, :string, default: nil, doc: "outer wrapper utilities (e.g. mt-2 in notifications)")
  attr(:rest, :global, doc: "data-* hooks land on the excerpt link, which owns the permalink")

  def post_preview(assigns) do
    ~H"""
    <div class={["flex items-start gap-3", @class]}>
      <.link href={~p"/#{@post.user}"} class="shrink-0" aria-hidden="true" tabindex="-1">
        <.avatar user={@post.user} size="sm" />
      </.link>
      <div class="min-w-0 flex-1">
        <div class="flex flex-wrap items-baseline gap-x-2">
          <.link
            href={~p"/#{@post.user}"}
            class="font-semibold text-slate-900 hover:text-brand-700 dark:text-white"
          >
            {full_name(@post.user)}
          </.link>
          <span class="text-xs text-slate-600 dark:text-slate-400">
            {"@" <> @post.user.username} ·
            <.post_time id={@time_id} at={@post.inserted_at} />
          </span>
        </div>
        <span
          :if={@label}
          class="mt-0.5 block text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400"
        >
          {@label}
        </span>
        <.link href={Posts.path(@post)} class="mt-0.5 block" {@rest}>
          <p class={["text-sm text-slate-700 hover:text-brand-700 dark:text-slate-300", @clamp]}>
            {@text}<span :if={@truncated?}>…</span>
          </p>
        </.link>
      </div>
    </div>
    """
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

      <.reposted_banner reposters={@reposters} />

      <%!-- The reply banner: the live parent links its permalink; a deleted
      parent degrades to the author's profile, a deleted account to a
      nameless notice (no name retained past account deletion). --%>
      <%= case @reply_banner do %>
        <% {:parent, parent_author, parent_path} -> %>
          <.reply_banner_line variant="parent">
            <.link href={parent_path} class="hover:text-brand-700">
              {gettext("Replying to %{handle}", handle: handle(parent_author))}
            </.link>
          </.reply_banner_line>
        <% {:author_only, parent_author} -> %>
          <.reply_banner_line variant="author-only">
            <.link href={~p"/#{parent_author}"} class="hover:text-brand-700">
              {gettext("Reply to a now-deleted post by %{handle}", handle: handle(parent_author))}
            </.link>
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
        <.link href={~p"/#{@post.user}"} class="shrink-0" aria-hidden="true" tabindex="-1">
          <.avatar user={@post.user} size="sm" presence />
        </.link>

        <div class="min-w-0 flex-1">
          <%!-- The ⋯ menu rides this header row (right-aligned via the name
          block's flex-1) so the body below spans the full content column. When
          the menu was a sibling of that column it narrowed it for its whole
          height, and the body text wrapped early at the menu's left edge. --%>
          <div class="flex items-start gap-2">
            <div class="flex min-w-0 flex-1 flex-wrap items-baseline gap-x-2">
              <.link
                href={~p"/#{@post.user}"}
                class="font-semibold text-slate-900 hover:text-brand-700 dark:text-white"
              >
                {full_name(@post.user)}
              </.link>
              <.link href={@permalink} class="text-sm text-slate-600 dark:text-slate-400 hover:text-brand-700">
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
                  :if={!@pinned_to_profile?}
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
                  :if={@pinned_to_profile?}
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
                  :if={@viewer_follow}
                  href={~p"/follows/#{@viewer_follow.id}/mute"}
                  method="put"
                >
                  {if @viewer_follow.muted?,
                    do: gettext("Unmute @%{handle}", handle: @post.user.username),
                    else: gettext("Mute @%{handle}", handle: @post.user.username)}
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
                class="markdown markdown--post mt-2 text-slate-800 dark:text-slate-200"
                {style_attrs(@body_style)}
              >
                <.link_screenshot_image
                  :if={@link_screenshot}
                  screenshot={@link_screenshot}
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
                class="mt-2"
                tags={@post.tags}
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
                class="mt-2"
                tags={@post.tags}
                wrap
              >
                <:float>
                  <.link_screenshot_image
                    screenshot={@link_screenshot}
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
                class="mt-2"
                media={@inline_media?}
                tags={@post.tags}
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

          <%!-- AI-moderation limbo. For every viewer but the author/admin a
          pending image renders as this neutral placecard tile; the author
          instead sees the image (filtered in above) plus the amber pill. --%>
          <div
            :if={@held_count > 0}
            class={["mt-3 grid gap-2", @held_count > 1 && "grid-cols-2"]}
            data-image-placecards
          >
            <div
              :for={_placecard <- 1..@held_count//1}
              class="flex aspect-[4/3] w-full flex-col items-center justify-center gap-2 rounded-lg bg-slate-100 ring-1 ring-slate-200 dark:bg-slate-800 dark:ring-slate-700"
            >
              <.hourglass class="h-7 w-7 text-slate-400 dark:text-slate-500" />
              <span class="px-2 text-center text-xs text-slate-600 dark:text-slate-400">
                {gettext("Photo is being checked")}
              </span>
            </div>
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
  # in via @body_style), faded at the bottom, with a "Read more" affordance
  # riding the last line.
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
  attr(:class, :string, default: nil)
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
            "markdown markdown--post text-slate-800 dark:text-slate-200"
          ]}
          data-clamp-body
          data-post-body
          {style_attrs(@body_style)}
        >
          <%!-- The floated media is the clamp block's FIRST child so the body text
          wraps around it; the block contains + clips it (flow-root + overflow). --%>
          {render_slot(@float)}
          {@body_html}
          <.post_tags :if={@wrap or @media} tags={@tags} class="post-preview__tags-inline" />
        </div>
        <%!-- Fades the clamp cut into the card so it reads as intentional; only
        visible once the hook sets `is-clamped`, and cleared again while
        `is-expanded`. --%>
        <div class="post-preview__fade" aria-hidden="true"></div>
        <%!-- The whole body is present, so "Read more" expands it in place. --%>
        <button
          type="button"
          data-read-more
          data-post-expand
          aria-expanded="false"
          aria-controls={@body_id}
          data-label-more={gettext("Read more")}
          data-label-less={gettext("Show less")}
          class="post-preview__more text-sm font-medium text-brand-600 hover:text-brand-700"
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

  defp post_gallery(%{mode: :preview} = assigns), do: mosaic(assigns)

  defp post_gallery(assigns) do
    ~H"""
    <div
      class={["grid gap-2 mt-4", length(@gallery) > 1 && "sm:grid-cols-2"]}
      data-lightbox-gallery
      data-label-close={gettext("Close")}
      data-label-prev={gettext("Previous photo")}
      data-label-next={gettext("Next photo")}
      data-label-download={gettext("Download the original")}
    >
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
    </div>
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
      left-hand tile and the mosaic a portrait-ish frame; a landscape hero
      gets a wide top tile and a landscape frame
      (`VutuvWeb.PostComponents.mosaic_layout/1`). A mosaic crops — that is
      what makes it a mosaic — and choosing the frame from the photos is what
      keeps the crop gentle instead of chopping every picture to one
      hardcoded band.

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

  def mosaic(assigns) do
    layout = mosaic_layout(assigns.gallery)

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
        <img
          src={PostImage.url(cell.image, "feed")}
          alt={photo_alt(cell.image)}
          loading="lazy"
          class="h-full w-full object-cover"
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

  # How many tiles a mosaic draws before the rest collapse into the `+N`.
  # Five is what the layouts below are drawn for, and the point past which
  # tiles get too small to be worth loading.
  @mosaic_tiles 5

  @doc """
  The tile arrangement for a photo set: `%{aspect: "7 / 5", cells: [...]}`,
  each cell carrying its image, its CSS `grid-area` on the shared 12×6 grid
  and how many further photos it stands for (`more`, non-zero on the last tile
  only).

  Public so `mosaic_layout_test.exs` can check the geometry directly — the
  arrangement is the feature, and it is much easier to get wrong than to see
  wrong.
  """
  def mosaic_layout(gallery) do
    shown = Enum.take(gallery, @mosaic_tiles)
    more = length(gallery) - length(shown)
    hero = List.first(shown)
    tall? = hero && PostImage.orientation(hero) == :portrait

    {aspect, areas} = mosaic_shape(length(shown), tall?)

    cells =
      shown
      |> Enum.zip(areas)
      |> Enum.with_index()
      |> Enum.map(fn {{image, area}, index} ->
        %{image: image, area: area, more: if(index == length(shown) - 1, do: more, else: 0)}
      end)

    %{aspect: aspect, cells: cells}
  end

  # The arrangements, on a 12×6 grid (`row-start / col-start / row-end /
  # col-end`). Twelve columns divide by two, three, four and six, which is
  # every split these layouts need; six rows do the same vertically. A coarser
  # grid was tried first and could not express the tall-hero five-photo case
  # without cropping the hero the wrong way.
  #
  # **What is tuned here is the hero cell, not the frame.** A cell's aspect is
  # `frame_ratio × (cell_cols / 12) ÷ (cell_rows / 6)`, so the frame and the
  # hero's own tile pull in opposite directions — a portrait hero wants a
  # *wider* frame when its tile is narrow and full-height. That is the whole
  # "aspect-aware" claim and the reason each count carries a portrait and a
  # landscape variant instead of one compromise that crops both.
  # `mosaic_layout_test.exs` asserts the resulting hero-cell shape.

  # Two photos sit side by side either way (stacking a pair makes a card twice
  # as tall as it is wide); only the frame differs, which is what decides
  # whether the pair reads as two portraits or two landscapes.
  defp mosaic_shape(2, tall?) do
    {if(tall?, do: "7 / 5", else: "14 / 5"), ["1 / 1 / 7 / 7", "1 / 7 / 7 / 13"]}
  end

  # A portrait hero takes the left two thirds full height, with two stacked
  # beside it; a landscape hero takes the top two thirds full width, with two
  # side by side below.
  defp mosaic_shape(3, true) do
    {"6 / 5", ["1 / 1 / 7 / 9", "1 / 9 / 4 / 13", "4 / 9 / 7 / 13"]}
  end

  defp mosaic_shape(3, false) do
    {"1 / 1", ["1 / 1 / 5 / 13", "5 / 1 / 7 / 7", "5 / 7 / 7 / 13"]}
  end

  # Four photos are the one count with a symmetric answer: a 2×2 grid, where
  # every cell inherits the frame's aspect exactly, so all four crop equally
  # little.
  defp mosaic_shape(4, tall?) do
    {if(tall?, do: "4 / 5", else: "3 / 2"),
     ["1 / 1 / 4 / 7", "1 / 7 / 4 / 13", "4 / 1 / 7 / 7", "4 / 7 / 7 / 13"]}
  end

  # Five, portrait hero: the hero fills the left half top to bottom and the
  # other four sit in a 2×2 beside it, so all five tiles come out portrait.
  defp mosaic_shape(5, true) do
    {"7 / 5",
     [
       "1 / 1 / 7 / 7",
       "1 / 7 / 4 / 10",
       "1 / 10 / 4 / 13",
       "4 / 7 / 7 / 10",
       "4 / 10 / 7 / 13"
     ]}
  end

  # Five, landscape hero: the hero over two thirds of both axes, two stacked
  # at its right and two across the bottom.
  defp mosaic_shape(5, false) do
    {"3 / 2",
     [
       "1 / 1 / 5 / 9",
       "1 / 9 / 3 / 13",
       "3 / 9 / 5 / 13",
       "5 / 1 / 7 / 5",
       "5 / 5 / 7 / 13"
     ]}
  end

  # A single tile (and the defensive zero case) simply fills the frame; the
  # post card routes one photo to its own full-width treatment before it ever
  # gets here.
  defp mosaic_shape(_count, tall?) do
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
  # exposure settings. Formatted the way the post timestamps already branch
  # (`VutuvWeb.UI.post_time/1`), so dates read the same across the card.
  defp taken_on(%PostImage{taken_at: taken_at}) do
    case Gettext.get_locale(VutuvWeb.Gettext) do
      "de" -> Calendar.strftime(taken_at, "%d.%m.%Y")
      _other -> Calendar.strftime(taken_at, "%b %-d, %Y")
    end
  end

  # The envelope of shapes a photo is shown **whole** in, in the feed.
  # Everything a camera or a phone actually produces lives inside it: 4:3
  # (1.33), 3:2 (1.5), 16:9 (1.78) and their portrait mirrors down to 9:16
  # (0.5625). Outside it are the deliberate extremes — a stitched panorama, a
  # full-page screenshot, a tall infographic — which at column width would
  # either be a letterbox slit or a photo the reader has to scroll past.
  # Those are cropped to the nearest ordinary frame instead.
  @whole_ratio_max 2.0
  @whole_ratio_min 0.5

  @doc """
  How a lone photo is fitted into a feed card (issue #1104): `:whole`, or
  `{:crop, aspect}` for a shape too extreme to show at column width.

  **A single photo is not cropped.** The old card forced every one into a
  24rem-tall `object-cover` box, which cut the top and bottom off any portrait
  — the shape a phone takes by default. Now an ordinary photo is shown
  complete and merely bounded in height, so it can be *smaller* than the
  column but never a fragment of itself.

  The exceptions are the shapes that are not really "a photo" at column width:
  past 2:1 a panorama becomes a slit, past 1:2 a tower turns the card into a
  scroll. Those crop to 2:1 and 3:4 — a normal frame, as the issue asks — and
  the permalink still shows them whole.

  Public for `single_photo_fit_test.exs`: the boundary is the feature, and a
  ratio rule is the kind of thing that reads correct and is off by a factor.
  """
  def feed_photo_fit(%PostImage{} = image) do
    ratio = PostImage.aspect(image)

    cond do
      ratio > @whole_ratio_max -> {:crop, "2 / 1"}
      ratio < @whole_ratio_min -> {:crop, "3 / 4"}
      true -> :whole
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

  @doc """
  The turning hourglass shown while a photo waits for the AI image scan
  (issue #1104).

  An hourglass rather than a spinner on purpose: a spinner says "loading", and
  what is happening here is not a load but a wait for something being *judged*
  — with a duration the reader cannot control and should not expect to be
  instant. The rotation is CSS (`.hourglass`, `components.css`) and stops
  under `prefers-reduced-motion`; the glyph reads the same either way.
  """
  attr(:class, :string, default: "h-5 w-5")

  def hourglass(assigns) do
    ~H"""
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.5"
      class={["hourglass shrink-0", @class]}
      aria-hidden="true"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M6.75 2.25h10.5M6.75 21.75h10.5M7.5 2.25v3.336c0 .58.226 1.136.63 1.55L12 11l3.87-3.864c.404-.414.63-.97.63-1.55V2.25M7.5 21.75v-3.336c0-.58.226-1.136.63-1.55L12 13l3.87 3.864c.404.414.63.97.63 1.55v3.336"
      />
    </svg>
    """
  end

  @doc """
  The author's "not public yet, we are checking your photos" banner
  (issue #1104).

  A post waits for **all** of its photos before it goes anywhere
  (`Vutuv.Posts.moderation_hidden?/1`), so this banner has to carry the one
  fact the author would otherwise get wrong: the post exists, they can see it,
  and **nobody else can yet**. It says that first, then that a check is running
  right now (the turning hourglass), then how far it has got on a multi-photo
  post ("2 of 5 done") — and it disappears by itself the moment the last photo
  clears, which is the answer to "when does it go live".

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
          {gettext("Only you can see this post so far.")}
        </span>
        <span class="mt-0.5 block">
          {ngettext(
            "Our AI is checking the photo. As soon as it is through, the post goes live by itself.",
            "Our AI is checking the photos, %{done} of %{total} done. As soon as the last one is through, the post goes live by itself.",
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
  # the profile job pin has its own star (`WorkExperienceHTML.pin_star/1`).
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

    assigns =
      assigns
      |> assign(:primary, hd(reposters))
      |> assign(:cap, @repost_stack_cap)
      # Everyone besides the named (newest) reposter — the "and N others" tail.
      |> assign(:others, length(reposters) - 1)

    ~H"""
    <div
      class="mb-3 flex items-center gap-2 text-xs font-semibold text-slate-600 dark:text-slate-400"
      data-reposted-by={@primary.id}
    >
      <.icon_repost class="h-4 w-4 shrink-0" />
      <%!-- The stack's avatars link to each reposter; the sentence beside it
      names them, so the stack itself is decorative for assistive tech. --%>
      <.avatar_stack users={@reposters} cap={@cap} />
      <span class="min-w-0 truncate">
        <%= if @others == 0 do %>
          <.link href={~p"/#{@primary}"} class="hover:text-brand-700">
            {gettext("Reposted by %{name}", name: full_name(@primary))}
          </.link>
        <% else %>
          {ngettext(
            "Reposted by %{name} and %{formatted} other",
            "Reposted by %{name} and %{formatted} others",
            @others,
            name: full_name(@primary),
            formatted: compact_count(@others)
          )}
        <% end %>
      </span>
    </div>
    """
  end

  # The three banner states a reply card can be in, resolved from the
  # preloaded reply_ref (one level deep — `Vutuv.Posts.post_preloads/0`).
  # Pattern-match the structs: an un-preloaded has_one is a truthy
  # %Ecto.Association.NotLoaded{}. `show?` is false where the caller already
  # shows the parent post inline (the profile thread), so the banner is dropped.
  defp reply_banner(_post, false), do: nil
  defp reply_banner(post, true), do: reply_banner(post)

  defp reply_banner(post) do
    case Posts.reply_ref_state(post) do
      {:parent, parent} -> {:parent, parent.user, Posts.path(parent)}
      state -> state
    end
  end

  # Reply system messages name the account handle, never the clear name.
  defp handle(%User{username: username}), do: "@" <> username

  # Whether to float a post's single image beside its body (the text wraps around
  # and below it, `.post-clamp--wrap`) rather than stacking a full-width image
  # below the text. True only in preview mode, with body text for the float to
  # wrap, exactly one image, and that image roughly square (see square_image?/1).
  # Anything else keeps the existing full-width single / multi-image treatment.
  defp square_layout?(post, gallery, :preview) do
    post.body != "" and match?([_], gallery) and square_image?(hd(gallery))
  end

  defp square_layout?(_post, _gallery, _mode), do: false

  # AI-moderation limbo: the author and admins keep seeing a pending image
  # (the proxy serves it to them); everyone else gets `held_count` placecard
  # tiles instead of the image (Vutuv.Moderation.ImageScans).
  defp split_gallery(post, viewer) do
    images = if is_list(post.images), do: post.images, else: []

    if Posts.author?(post, viewer) or match?(%User{admin?: true}, viewer) do
      {images, 0}
    else
      {released, held} = Enum.split_with(images, &ImageScans.released?(&1.moderation))
      {released, length(held)}
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
  defp link_screenshot(%{images: [], screenshot: %PostScreenshot{} = ps}) do
    if PostScreenshot.ready?(ps), do: ps
  end

  defp link_screenshot(_post), do: nil

  # Whether the PREVIEW needs the float-wrap body layout for the link screenshot
  # (a height clamp instead of a line clamp, since `-webkit-line-clamp` cannot
  # wrap text around a float). Full mode floats the screenshot too, but its body
  # is unclamped, so it just renders it inside the body div — no flag needed.
  defp link_screenshot_layout?(post, :preview), do: link_screenshot(post) != nil
  defp link_screenshot_layout?(_post, _mode), do: false

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
    do: "text-brand-600 hover:text-brand-700 dark:text-brand-300 dark:hover:text-brand-200"

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
      <img
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

  attr(:target, :any,
    default: nil,
    doc: "phx-target: the LiveComponent's @myself on a host page, nil on a dead page"
  )

  def post_actions(assigns) do
    assigns =
      assign(
        assigns,
        :own?,
        assigns.engagement != nil and assigns.viewer_id != nil and
          assigns.engagement.author_id == assigns.viewer_id
      )

    ~H"""
    <%!-- justify-between spreads the four controls across the column's full
          width (X-style); -mx-2 cancels the outer buttons' px-2 so the first
          and last glyphs line up with the column edges. --%>
    <div
      :if={@engagement}
      class="-mx-2 mt-3 flex items-center justify-between gap-2 text-slate-600 dark:text-slate-400"
    >
      <.like_control
        id={"#{@id}-like"}
        target={@target}
        own?={@own?}
        liked?={@engagement.liked?}
        count={@engagement.likes}
      />

      <.reply_link
        id={"#{@id}-reply"}
        post_id={@post_id}
        count={@engagement.replies}
        disabled={@engagement.restricted?}
      />

      <.action_button
        id={"#{@id}-repost"}
        target={@target}
        kind="repost"
        active?={@engagement.reposted?}
        count={@engagement.reposts}
        label={if @engagement.reposted?, do: gettext("Undo repost"), else: gettext("Repost")}
        active_class="text-brand-600 dark:text-brand-300"
        disabled={@engagement.restricted?}
        disabled_title={gettext("Only public posts can be reposted.")}
      >
        <:icon><.icon_repost /></:icon>
      </.action_button>

      <.action_button
        id={"#{@id}-bookmark"}
        target={@target}
        kind="bookmark"
        active?={@engagement.bookmarked?}
        count={@engagement.bookmarks}
        label={if @engagement.bookmarked?, do: gettext("Remove bookmark"), else: gettext("Bookmark")}
        active_class="text-brand-600 dark:text-brand-300"
      >
        <:icon><.icon_bookmark filled?={@engagement.bookmarked?} /></:icon>
      </.action_button>
    </div>

    <.fediverse_line
      :if={@engagement}
      reactions={@engagement.fediverse_reactions}
      replies={Map.get(@engagement, :fediverse_replies, 0)}
    />
    """
  end

  # What other networks did with this post (issues #1068 and #1069): labelled
  # counts on their OWN line under the vutuv counters, never folded into them. A
  # member who publishes outward otherwise gets no feedback at all, and keeping
  # the figures separate means a hostile remote server can inflate only its own
  # line — and the reader can see which world answered. Public, because both are
  # aggregates with no identity attached; the reply figure counts **public**
  # replies only, so a note addressed to the member alone (issue #1071) never
  # moves a number a stranger can read. Renders nothing while both are zero, so
  # a post nobody out there touched stays clean.
  attr(:reactions, :integer, required: true)
  attr(:replies, :integer, required: true)

  defp fediverse_line(%{reactions: reactions, replies: replies} = assigns)
       when reactions > 0 or replies > 0 do
    assigns = assign(assigns, :text, fediverse_line_text(reactions, replies))

    ~H"""
    <div
      class="mt-2 border-t border-slate-100 pt-2 text-sm text-slate-600 dark:border-slate-800 dark:text-slate-400"
      data-fediverse-reactions={@reactions}
      data-fediverse-replies={@replies}
    >
      <span aria-hidden="true" class="mr-1">🌐</span>{@text}
    </div>
    """
  end

  defp fediverse_line(assigns), do: ~H""

  # One **whole** sentence per case, never a line assembled from fragments: the
  # figures go in as placeholders so a translator owns the word order (German
  # would otherwise be at the mercy of where the English happens to put "from
  # other networks"). The noun phrases are their own ngettext calls, because
  # only they need the singular/plural split.
  defp fediverse_line_text(reactions, 0), do: gettext_from_networks(reaction_phrase(reactions))
  defp fediverse_line_text(0, replies), do: gettext_from_networks(reply_phrase(replies))

  defp fediverse_line_text(reactions, replies) do
    gettext("%{reactions} and %{replies} from other networks",
      reactions: reaction_phrase(reactions),
      replies: reply_phrase(replies)
    )
  end

  defp gettext_from_networks(phrase),
    do: gettext("%{count} from other networks", count: phrase)

  defp reaction_phrase(count) do
    ngettext("%{formatted} reaction", "%{formatted} reactions", count,
      formatted: compact_count(count)
    )
  end

  defp reply_phrase(count) do
    ngettext("%{formatted} reply", "%{formatted} replies", count, formatted: compact_count(count))
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
      label={if @liked?, do: gettext("Unlike"), else: gettext("Like")}
      active_class="text-accent"
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
  # mirroring the disabled repost button.
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
  attr(:label, :string, required: true)
  attr(:active_class, :string, required: true)
  attr(:disabled, :boolean, default: false)
  attr(:disabled_title, :string, default: nil)
  slot(:icon, required: true)

  defp action_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-click="toggle"
      phx-target={@target}
      phx-value-kind={@kind}
      disabled={@disabled}
      aria-pressed={to_string(@active?)}
      aria-label={@label}
      title={if(@disabled, do: @disabled_title, else: @label)}
      class={[
        "inline-flex items-center gap-1.5 rounded-lg px-2 py-1 text-sm",
        @disabled && "cursor-not-allowed opacity-40",
        !@disabled && "hover:bg-slate-100 dark:hover:bg-slate-800",
        # components.css colors bare `a, button` brand-600, which beats the
        # wrapper's inherited slate — so the state color sits on the button.
        if(@active?, do: @active_class, else: "text-slate-600 dark:text-slate-400")
      ]}
    >
      {render_slot(@icon)}
      <%!-- Always mounted (invisible at zero) so an arriving first count
            doesn't shift the neighbouring buttons under the pointer. --%>
      <.count_pill count={@count} kind={@kind} />
    </button>
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
