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
  alias Vutuv.Isbn
  alias Vutuv.Moderation.ImageScans
  alias Vutuv.Posts
  alias Vutuv.Posts.PostImage
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
      |> assign(
        :limbo_pill?,
        Enum.any?(shown_images, &(&1.moderation == "pending"))
      )
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
      |> assign(:report_menu_id, "post-report-#{entry_key}")
      |> assign(:time_id, "post-time-#{entry_key}")
      |> assign(:body_id, "post-body-#{entry_key}")
      |> assign(:author?, Posts.author?(post, viewer))
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
        <.composer_trigger_body viewer={@viewer} surface={@surface}>
          {render_slot(@inner_block)}
        </.composer_trigger_body>
      </.link>
    <% else %>
      <button type="button" data-composer-trigger class={@shell_class} {@rest}>
        <.composer_trigger_body viewer={@viewer} surface={@surface}>
          {render_slot(@inner_block)}
        </.composer_trigger_body>
      </button>
    <% end %>
    """
  end

  attr(:viewer, :any, required: true)
  attr(:surface, :atom, required: true)
  slot(:inner_block, required: true)

  # Standalone (:card, the feed) carries the big `md` avatar as the page's
  # anchor. Flat (:flat) sits among post rows, so it follows their grammar:
  # the same `sm` avatar the post headers use (a bigger one towers over the
  # list and shifts the pill off the post text column) and a py-2 pill, which
  # at text-sm comes out exactly avatar-high (36px).
  defp composer_trigger_body(assigns) do
    ~H"""
    <.avatar user={@viewer} size={if(@surface == :card, do: "md", else: "sm")} />
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
    assigns = assign(assigns, :chain, thread_chain_items(assigns))

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
      full post card (its own like / repost / bookmark bar), oldest-first, and
      every reply is nested one step further right under the post it answers —
      a left-rail, left-padded block per level — so the reply depth reads at a
      glance the way a threaded comment tree does. --%>
      <.thread_chain
        chain={@chain}
        viewer={@viewer}
        surface={@surface}
        conn_or_socket={@conn_or_socket}
      />
    <% end %>
    """
  end

  # The ordered card specs for a threaded conversation: the ancestors (oldest
  # first, banners off, engagement from the batched map) followed by the leaf
  # (which keeps its own follow edge, repost line and engagement). Each ancestor's
  # `entry_id` is derived from the leaf entry so DOM ids stay unique even when the
  # same post is nested under more than one reply on the page.
  defp thread_chain_items(assigns) do
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

    ancestors ++
      [
        %{
          post: assigns.post,
          engagement: assigns.engagement,
          viewer_follow: assigns.viewer_follow,
          reposted_by: assigns.reposted_by,
          reposters: assigns.reposters,
          entry_id: assigns.entry_id
        }
      ]
  end

  # How many levels of a thread visibly indent before the indentation is capped.
  # Beyond this, deeper replies keep stacking in the same column (the connector
  # becomes a straight vertical drop) instead of marching further right. A card's
  # min-content is ~267px and a 360px phone (the narrow floor we support) leaves
  # ~60px of slack past that, so 2 levels of `pl-7` (28px) stay comfortably
  # on-screen; letting the indent grow unbounded scrolled a deep thread sideways.
  @thread_indent_cap 2

  # Renders a reply chain as a threaded conversation with a **connector line that
  # runs from each avatar into the reply's avatar** (like a mail/forum thread):
  # a vertical drop from the head avatar down its card, then — in the indented
  # block holding the reply — an elbow that curves from that column into the
  # reply's avatar. Each reply is indented one `pl-7` step under the post it
  # answers until the indent is capped (see above), past which replies stay in
  # the same column and the connector is a straight vertical drop. Recursion draws
  # the same connector at every level, so the line threads avatar-to-avatar all
  # the way down. The avatar centre is `1.125rem` in from the card's left (the
  # `sm` avatar), which is why the connectors sit at `left-[1.125rem]`.
  attr(:chain, :list, required: true)
  attr(:depth, :integer, default: 0)
  attr(:viewer, :any, default: nil)
  attr(:surface, :atom, required: true)
  attr(:conn_or_socket, :any, required: true)

  defp thread_chain(assigns) do
    # `@thread_indent_cap` is a module attribute, not an assign, so resolve the
    # "still indenting?" flag here — inside ~H, `@name` would mean assigns.name.
    assigns = assign(assigns, :indent?, assigns.depth < @thread_indent_cap)

    ~H"""
    <%= case @chain do %>
      <% [item | rest] -> %>
        <div class="relative">
          <%!-- Drops from this avatar's bottom (top-9) to the card's bottom; the
          elbow below continues it into the reply's avatar. Only when a reply
          follows this card. Height is an explicit `calc(100% - top)`, not
          `top-9` + `bottom-0`: an empty absolutely-positioned box sized only by
          `top`/`bottom` (auto height) collapses to zero on iOS/mobile Safari, so
          the whole thread line vanished on phones while the explicit-height
          elbows survived. An explicit height renders identically everywhere. --%>
          <span
            :if={rest != []}
            class="absolute left-[1.125rem] top-9 h-[calc(100%-2.25rem)] w-0.5 rounded-full bg-slate-200 dark:bg-slate-700"
            aria-hidden="true"
          >
          </span>
          <.post_card
            post={item.post}
            viewer={@viewer}
            viewer_follow={item.viewer_follow}
            engagement={item.engagement}
            reposted_by={item.reposted_by}
            reposters={item.reposters}
            entry_id={item.entry_id}
            surface={@surface}
            conn_or_socket={@conn_or_socket}
            show_reply_banner={false}
          />
        </div>
        <div :if={rest != []} class={["relative pt-3", @indent? && "pl-7"]}>
          <%!-- The connector into the reply's avatar. Indented: an elbow curving
          from the parent column (left-[1.125rem]) right into the reply avatar's
          left edge, at the reply avatar's vertical centre (pt-3 + 1.125rem =
          1.875rem down). Capped: the reply is in the same column, so a straight
          vertical drop to its avatar. --%>
          <span
            :if={@indent?}
            class="absolute left-[1.125rem] top-0 h-[1.875rem] w-2.5 rounded-bl-xl border-b-2 border-l-2 border-slate-200 dark:border-slate-700"
            aria-hidden="true"
          >
          </span>
          <span
            :if={!@indent?}
            class="absolute left-[1.125rem] top-0 h-3 w-0.5 rounded-full bg-slate-200 dark:bg-slate-700"
            aria-hidden="true"
          >
          </span>
          <.thread_chain
            chain={rest}
            depth={@depth + 1}
            viewer={@viewer}
            surface={@surface}
            conn_or_socket={@conn_or_socket}
          />
        </div>
      <% [] -> %>
    <% end %>
    """
  end

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
    <div>
      <%!-- The owner's freezer notice: only the author (and admins) still see
      a reported post; everyone else gets nothing, not even a tombstone. --%>
      <.frozen_banner :if={@frozen? and @author?} class="mb-3 rounded-lg px-3 py-2 text-xs">
        {gettext("Only you can see this post while a report about it is handled.")}
      </.frozen_banner>

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

            <%!-- The author's quiet ⋯ menu, on every rendering of their post. --%>
            <div :if={@author?} class="-mr-1 -mt-1 shrink-0">
              <.card_menu id={@menu_id}>
                <:item href={~p"/posts/#{@post.id}/edit"}>{gettext("Edit")}</:item>
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
              image keeps the feed-compact treatment (a squarish one floats
              above; anything else stacks full-width, height-capped at 24rem so
              one post can't run away down the timeline). Multiple images tile
              through the shared `post_gallery` — natural aspect, no crop, the
              same way the permalink shows them (it used to crop each tile to
              `aspect-[4/3]`, chopping content to a middle band). --%>
              <.link
                :if={length(@gallery) == 1}
                href={@permalink}
                aria-label={gettext("View post")}
                class="mt-3 block"
              >
                <img
                  src={PostImage.url(hd(@gallery), "feed")}
                  alt={hd(@gallery).alt}
                  width={hd(@gallery).width}
                  height={hd(@gallery).height}
                  loading="lazy"
                  class="max-h-96 w-full rounded-lg object-cover ring-1 ring-slate-200 dark:ring-slate-800"
                />
              </.link>
              <.post_gallery
                :if={length(@gallery) > 1}
                gallery={@gallery}
                mode={:preview}
                permalink={@permalink}
              />
            <% true -> %>
              <.post_gallery
                :if={@gallery != []}
                gallery={@gallery}
                mode={:full}
                permalink={@permalink}
              />
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
              <svg
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="1.5"
                class="h-8 w-8 text-slate-400 dark:text-slate-500"
                aria-hidden="true"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="m2.25 15.75 5.159-5.159a2.25 2.25 0 0 1 3.182 0l5.159 5.159m-1.5-1.5 1.409-1.409a2.25 2.25 0 0 1 3.182 0l2.909 2.909M3.75 21h16.5A1.5 1.5 0 0 0 21.75 19.5V4.5A1.5 1.5 0 0 0 20.25 3H3.75A1.5 1.5 0 0 0 2.25 4.5v15A1.5 1.5 0 0 0 3.75 21Z"
                />
              </svg>
              <span class="px-2 text-center text-xs text-slate-600 dark:text-slate-400">
                {gettext("Image is being reviewed")}
              </span>
            </div>
          </div>

          <p
            :if={@limbo_pill?}
            class="mt-2 inline-flex items-center gap-1.5 rounded-full bg-amber-50 px-2.5 py-1 text-xs font-medium text-amber-800 ring-1 ring-amber-200 dark:bg-amber-900/30 dark:text-amber-200 dark:ring-amber-800"
            data-image-pending-pill
          >
            {gettext("Image awaiting review, visible only to you")}
          </p>


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
  # inline (`![](…)`), rendered at their **natural aspect ratio** — no crop — so
  # a screenshot or panorama reads whole. One image fills the column; several
  # tile 1-up on phones, 2-up on `sm+`. This is the ONE gallery rendering shared
  # by the preview (feed / profile) and the permalink, so the two look identical:
  # the preview grid used to force every tile to `aspect-[4/3]`, chopping content
  # down to a middle band and looking worse than the permalink. The `feed` image
  # version is already aspect-preserving (`box_down 1200`), so `w-full` alone
  # shows it uncropped.
  #
  # The only mode difference is the click target: a `:preview` tile opens the
  # post (its permalink), a `:full` tile opens the `large` version in a new tab
  # (the lightbox). A `false` value on `target`/`rel`/`aria-label` drops the
  # attribute, so each mode carries only the attributes it needs.
  attr(:gallery, :list, required: true)
  attr(:mode, :atom, required: true, values: [:preview, :full])
  attr(:permalink, :string, required: true)

  defp post_gallery(assigns) do
    ~H"""
    <div class={[
      "grid gap-2",
      (@mode == :full && "mt-4") || "mt-3",
      length(@gallery) > 1 && "sm:grid-cols-2"
    ]}>
      <.link
        :for={image <- @gallery}
        href={(@mode == :full && PostImage.url(image, "large")) || @permalink}
        target={@mode == :full && "_blank"}
        rel={@mode == :full && "noopener"}
        aria-label={@mode == :preview && gettext("View post")}
        class="block overflow-hidden rounded-lg ring-1 ring-slate-200 dark:ring-slate-800"
      >
        <img
          src={PostImage.url(image, "feed")}
          alt={image.alt}
          width={image.width}
          height={image.height}
          loading="lazy"
          class="w-full object-cover"
        />
      </.link>
    </div>
    """
  end

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

  defp reposted_banner(%{reposters: []} = assigns), do: ~H""

  defp reposted_banner(assigns) do
    reposters = assigns.reposters
    shown = Enum.take(reposters, @repost_stack_cap)

    assigns =
      assigns
      |> assign(:primary, hd(reposters))
      |> assign(:shown, Enum.with_index(shown))
      |> assign(:overflow, length(reposters) - length(shown))
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
      <div class="flex shrink-0 items-center" aria-hidden="true">
        <.link
          :for={{reposter, i} <- @shown}
          href={~p"/#{reposter}"}
          title={full_name(reposter)}
          class={["rounded-full ring-2 ring-white dark:ring-slate-900", i > 0 && "-ml-1.5"]}
        >
          <.avatar user={reposter} size="2xs" />
        </.link>
        <span
          :if={@overflow > 0}
          class="-ml-1.5 inline-flex h-5 items-center rounded-full bg-slate-100 px-1.5 text-[10px] font-bold text-slate-600 ring-2 ring-white dark:bg-slate-800 dark:text-slate-300 dark:ring-slate-900"
        >
          +{compact_count(@overflow)}
        </span>
      </div>
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

    ~H"""
    <div
      class={[
        "mt-3 flex gap-3 rounded-xl bg-slate-50 p-3 ring-1 ring-slate-200 dark:bg-slate-800/50 dark:ring-slate-700",
        @aside && "md:mt-0 md:w-2/5 md:shrink-0"
      ]}
      data-review-card
      data-review-kind={@review.kind}
      data-review-aside={@aside && "true"}
    >
      <img
        :if={@cover_url}
        src={@cover_url}
        alt=""
        loading="lazy"
        class={[
          "w-16 self-start rounded-lg ring-1 ring-slate-200 dark:ring-slate-700 sm:w-20",
          @aside && "md:w-16"
        ]}
      />
      <span
        :if={!@cover_url}
        aria-hidden="true"
        class={[
          "flex aspect-[2/3] w-16 shrink-0 items-center justify-center self-start rounded-lg bg-brand-50 text-2xl dark:bg-brand-900/40 sm:w-20",
          @aside && "md:w-16"
        ]}
      >
        {if @review.kind == "movie", do: "🎬", else: "📖"}
      </span>

      <div class="min-w-0">
        <p class="text-xs font-semibold uppercase tracking-wide text-slate-500">
          {review_kind_label(@review.kind)}
        </p>
        <p class="mt-0.5 font-semibold text-slate-900 dark:text-slate-100">{@review.title}</p>
        <%!-- Creator · year · medium. In the narrow right-hand aside (`md` up)
        the creator keeps the first line and the year · medium drop onto the
        line below it, so a long author name no longer crowds the small facts;
        below `md` (and in the full-width non-aside card) it stays one line —
        the ` · ` separator shows and the meta stays inline. --%>
        <p
          :if={@review.creator || @review.year || @review.medium}
          class="text-sm text-slate-600 dark:text-slate-400"
        >{@review.creator}<span
            :if={@review.creator && review_year_medium(@review) != ""}
            class={@aside && "md:hidden"}
          > · </span><span
            :if={review_year_medium(@review) != ""}
            class={@aside && @review.creator && "md:block"}
            data-review-meta
          >{@review.year}{if @review.year && review_medium_label(@review.medium), do: " · "}<.review_medium review={@review} /></span></p>
        <%!-- The ISBN in its printed, hyphenated form (Vutuv.Isbn.format/1) —
        the stored value is the bare 13 digits, which reads as a barcode
        number rather than an ISBN. `whitespace-nowrap` keeps it on one line
        in the narrow aside: its hyphens are line-break opportunities, so it
        would otherwise split mid-number. --%>
        <p
          :if={@review.kind == "book" and @review.identifier}
          class="mt-1 text-xs text-slate-600 dark:text-slate-400"
        >
          ISBN <span class="whitespace-nowrap">{Isbn.format(@review.identifier)}</span>
        </p>
        <%!-- The outbound links on one dot-separated line: the book's own Open
        Library page first, then the store link (Amazon / IMDb). Both are plain
        brand links. The Open Library link shows only when a cover is actually
        rendered, because it also credits the source of that quoted image
        (§ 63 UrhG) — the courtesy link back Open Library asks for. --%>
        <p :if={@external_url || @cover_url} class="mt-1.5 text-sm text-slate-600 dark:text-slate-400">
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
    </div>
    """
  end

  # The medium word on the details line. An audiobook links the word to Audible
  # (PostReview.audible_url/1 — a title search, since Audible keys by its own
  # ASIN, not our print ISBN); every other medium stays plain text. Rendered as
  # the medium's own inline piece so only the word is the link, not the whole
  # year · medium line. Nothing at all for a review with no medium set.
  attr(:review, PostReview, required: true)

  defp review_medium(assigns) do
    assigns =
      assigns
      |> assign(:label, review_medium_label(assigns.review.medium))
      |> assign(:audible_url, PostReview.audible_url(assigns.review))

    ~H"""
    <%= cond do %>
      <% @label && @audible_url -> %>
        <.link
          href={@audible_url}
          target="_blank"
          rel="nofollow noopener noreferrer"
          class={review_link_class()}
        >{@label}</.link>
      <% @label -> %>
        {@label}
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

  defp review_kind_label("movie"), do: gettext("Film review")
  defp review_kind_label(_kind), do: gettext("Book review")

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
      [review.creator, review.year, review_medium_label(review.medium), isbn]
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

  # The outbound link reads as the bare store/database name — a proper noun,
  # identical in every locale, so no gettext.
  defp review_link_label("movie"), do: "IMDb"
  defp review_link_label(_kind), do: "Amazon"

  # The year · medium half of the details line (everything but the creator),
  # so the card can drop it onto its own line in the narrow aside. "" when the
  # review carries neither.
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

  attr(:target, :any,
    default: nil,
    doc: "phx-target: the LiveComponent's @myself on a host page, nil on a dead page"
  )

  def post_actions(assigns) do
    ~H"""
    <%!-- justify-between spreads the four controls across the column's full
          width (X-style); -mx-2 cancels the outer buttons' px-2 so the first
          and last glyphs line up with the column edges. --%>
    <div
      :if={@engagement}
      class="-mx-2 mt-3 flex items-center justify-between gap-2 text-slate-600 dark:text-slate-400"
    >
      <.action_button
        id={"#{@id}-like"}
        target={@target}
        kind="like"
        active?={@engagement.liked?}
        count={@engagement.likes}
        label={if @engagement.liked?, do: gettext("Unlike"), else: gettext("Like")}
        active_class="text-accent"
      >
        <:icon><.icon_heart filled?={@engagement.liked?} /></:icon>
      </.action_button>

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
