defmodule VutuvWeb.PostComponents do
  @moduledoc """
  The post card, shared by every place a post renders: the permalink page
  (`mode={:full}`), the feed and the profile section (`mode={:preview}`).

  Preview mode ships the whole body and clamps it to a few lines via CSS
  (`.post-clamp`); a "Read more" button expands it in place, so a long post
  reads the same on the feed and the profile. Attachments show as a thumbnail
  row. Full mode shows every attachment as a gallery below the body. Post
  bodies never embed images inline — uploaded pictures are always attachments,
  shown here.

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
  alias Vutuv.Posts
  alias Vutuv.Posts.PostImage
  alias Vutuv.Posts.PostScreenshot

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

    # The whole body is always shipped to the DOM. In :preview the `.post-clamp`
    # CSS line clamp does the visual cut and the in-place expand button reveals
    # the rest, so "Read more" expands in place instead of navigating to the
    # permalink — feed and profile alike. A preview never carries the post's
    # inline images (those show in the gallery below), so it renders with `[]`.
    images = if assigns.mode == :full, do: assigns.post.images, else: []
    body_html = VutuvWeb.Markdown.render_post(assigns.post.body, images)

    # A logged-in viewer (vs anonymous / a "View as public" preview, both nil),
    # bound once and reused for the acting-viewer id and the reporter test.
    viewer = assigns.viewer
    user? = match?(%User{}, viewer)

    # Every per-card DOM id derives from the timeline entry when there is one:
    # the same post can render twice on a page (original + repost), and the ids
    # must stay unique. Bound once here so the id assigns below don't each repeat
    # the `entry_id || post.id` fallback.
    entry_key = assigns.entry_id || assigns.post.id

    assigns =
      assigns
      |> assign(:body_html, body_html)
      # The inline CSS custom properties (`--post-clamp-*` / `--post-hyphens-*`)
      # that carry the reader's preference onto the post body; nil for a default
      # / logged-out reader, so their DOM stays clean and the CSS fallbacks apply.
      |> assign(:body_style, post_body_style(prefs))
      |> assign(:restricted?, Posts.restricted?(assigns.post))
      |> assign(:permalink, Posts.path(assigns.post))
      # Every attachment shows in the gallery (full mode) or the thumbnail row
      # (preview) — post bodies never embed images inline.
      |> assign(:gallery, assigns.post.images)
      |> assign(:square_layout?, square_layout?(assigns.post, assigns.mode))
      # The auto link screenshot (a ready %PostScreenshot{} for an image-less
      # single-URL post, else nil) and whether the preview lays it beside the
      # text (3/4 body, 1/4 screenshot).
      |> assign(:link_screenshot, link_screenshot(assigns.post))
      |> assign(:link_screenshot_layout?, link_screenshot_layout?(assigns.post, assigns.mode))
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
      |> assign(:author?, Posts.author?(assigns.post, viewer))
      |> assign(:reporter?, user? and not Posts.author?(assigns.post, viewer))
      |> assign(:frozen?, assigns.post.frozen_at != nil)
      |> assign(:reply_banner, reply_banner(assigns.post, assigns.show_reply_banner))
      |> assign(:reposters, repost_roster(assigns))
      |> assign(
        :edited?,
        NaiveDateTime.diff(assigns.post.updated_at, assigns.post.inserted_at) > 60
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

          <%!-- Full mode: the whole body, no clamp. The reader's hyphenation
          preference still rides along via @body_style (the clamp vars in it are
          simply unused here). --%>
          <div
            :if={@mode == :full and @post.body != ""}
            class="markdown markdown--post mt-2 text-slate-800 dark:text-slate-200"
            {style_attrs(@body_style)}
          >
            {@body_html}
          </div>

          <%= cond do %>
            <% @square_layout? -> %>
              <%!-- A single roughly-square image (see @square_ratio_*) laid out
              beside the body — 2/3 text, 1/3 image — so it shows in full instead
              of being cropped to a middle band by the full-width max-h cap. It
              stacks (text, then image below) on a phone, where the narrow column
              would not trigger the crop anyway. The image drops the max-h /
              object-cover of the full-width variant: at a third of the column a
              squarish image is never tall enough to need capping, so it renders
              at its natural aspect, whole. --%>
              <div class="mt-2 sm:flex sm:items-start sm:gap-4">
                <div class="min-w-0 sm:w-2/3">
                  <.preview_body
                    body_id={@body_id}
                    body_html={@body_html}
                    body_style={@body_style}
                  />
                  <%!-- Tags ride directly under the text inside the 2/3 column,
                  filling the space beside the image, rather than dropping to a
                  full-width row below the whole side-by-side block. --%>
                  <.post_tags tags={@post.tags} />
                </div>
                <.link
                  href={@permalink}
                  aria-label={gettext("View post")}
                  class="mt-3 block shrink-0 sm:mt-0 sm:w-1/3"
                >
                  <img
                    src={PostImage.url(hd(@post.images), "feed")}
                    alt={hd(@post.images).alt}
                    width={hd(@post.images).width}
                    height={hd(@post.images).height}
                    loading="lazy"
                    class="w-full rounded-lg ring-1 ring-slate-200 dark:ring-slate-800"
                  />
                </.link>
              </div>
            <% @link_screenshot_layout? -> %>
              <%!-- A single-URL, image-less post: the body beside a small
              screenshot of the linked page — 3/4 text, 1/4 screenshot — on
              iPad/desktop (md, so portrait iPads get the columns too), stacking
              (text, then screenshot below) on phones. --%>
              <div class="mt-2 md:flex md:items-start md:gap-4">
                <div class="min-w-0 md:w-3/4">
                  <.preview_body
                    body_id={@body_id}
                    body_html={@body_html}
                    body_style={@body_style}
                  />
                  <.post_tags tags={@post.tags} />
                </div>
                <.link_screenshot_image
                  screenshot={@link_screenshot}
                  class="mt-3 block shrink-0 md:mt-0 md:w-1/4"
                />
              </div>
            <% @mode == :preview -> %>
              <.preview_body
                :if={@post.body != ""}
                body_id={@body_id}
                body_html={@body_html}
                body_style={@body_style}
                class="mt-2"
              />

              <%!-- A single image keeps its aspect ratio at column width
              (height-capped) — square micro-thumbs would crop a panorama down
              to its middle sliver. Multiple images tile in a 2-up grid. --%>
              <.link
                :if={length(@post.images) == 1}
                href={@permalink}
                aria-label={gettext("View post")}
                class="mt-3 block"
              >
                <img
                  src={PostImage.url(hd(@post.images), "feed")}
                  alt={hd(@post.images).alt}
                  width={hd(@post.images).width}
                  height={hd(@post.images).height}
                  loading="lazy"
                  class="max-h-96 w-full rounded-lg object-cover ring-1 ring-slate-200 dark:ring-slate-800"
                />
              </.link>
              <div :if={length(@post.images) > 1} class="mt-3 grid grid-cols-2 gap-2">
                <.link :for={image <- @post.images} href={@permalink} aria-label={gettext("View post")} class="block">
                  <img
                    src={PostImage.url(image, "feed")}
                    alt={image.alt}
                    width={image.width}
                    height={image.height}
                    loading="lazy"
                    class="aspect-[4/3] w-full rounded-lg object-cover ring-1 ring-slate-200 dark:ring-slate-800"
                  />
                </.link>
              </div>
            <% true -> %>
              <div
                :if={@gallery != []}
                class={["mt-4 grid gap-2", length(@gallery) > 1 && "sm:grid-cols-2"]}
              >
                <a
                  :for={image <- @gallery}
                  href={PostImage.url(image, "large")}
                  target="_blank"
                  rel="noopener"
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
                </a>
              </div>
          <% end %>

          <%!-- Full mode (permalink): the link screenshot below the body — a
          single-URL post has no image gallery — at a modest width. --%>
          <.link_screenshot_image
            :if={@mode == :full and @link_screenshot}
            screenshot={@link_screenshot}
            class="mt-4 block max-w-md"
          />

          <%!-- Every non-square/non-screenshot layout puts the tags in their own
          full-width row below the body/images; the side-by-side layouts already
          rendered them inside the text column above. --%>
          <.post_tags :if={not @square_layout? and not @link_screenshot_layout?} tags={@post.tags} />

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

  defp preview_body(assigns) do
    ~H"""
    <div
      id={@body_id}
      phx-hook="PostPreviewClamp"
      data-post-preview
      class={["post-preview", @class]}
    >
      <div class="relative">
        <div
          class="markdown markdown--post post-clamp text-slate-800 dark:text-slate-200"
          data-clamp-body
          {style_attrs(@body_style)}
        >
          {@body_html}
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
    </div>
    """
  end

  # The post's tag chips row. Renders nothing when there are no tags, so callers
  # drop it in unconditionally. Shared by the full-width layouts (a row below the
  # body/images) and the square layout (under the text, inside the 2/3 column).
  attr(:tags, :list, required: true)

  defp post_tags(assigns) do
    ~H"""
    <div :if={@tags != []} class="mt-3 flex flex-wrap gap-2">
      <.chip :for={tag <- @tags} navigate={~p"/tags/#{tag}"}>{tag.name}</.chip>
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

  # Whether to lay a post's body and its single image out side by side (2/3 text,
  # 1/3 image) rather than stacking a full-width image below the text. True only
  # in preview mode, with body text to fill the left column, exactly one image,
  # and that image roughly square (see square_image?/1). Anything else keeps the
  # existing full-width single / multi-image treatment.
  defp square_layout?(post, :preview) do
    post.body != "" and match?([_], post.images) and square_image?(hd(post.images))
  end

  defp square_layout?(_post, _mode), do: false

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

  # Whether the preview lays the body out beside the link screenshot (3/4 text,
  # 1/4 screenshot). Only in preview mode with a ready screenshot; full mode
  # shows the screenshot below the body instead.
  defp link_screenshot_layout?(post, :preview), do: link_screenshot(post) != nil
  defp link_screenshot_layout?(_post, _mode), do: false

  # The link screenshot image, shared by the preview (1/4 column) and full
  # (below-body) layouts. A decorative duplicate of the body's autolinked URL —
  # `aria-hidden` + `tabindex=-1` so assistive tech and the tab order keep the
  # one link in the prose — opening the page in a new tab. `class` positions it.
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
