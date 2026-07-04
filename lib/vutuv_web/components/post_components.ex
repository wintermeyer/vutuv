defmodule VutuvWeb.PostComponents do
  @moduledoc """
  The post card, shared by every place a post renders: the permalink page
  (`mode={:full}`), the feed and the profile section (`mode={:preview}`).

  Preview mode cuts the Markdown server-side at a block boundary
  (`VutuvWeb.Markdown.render_preview/2`), clamps to a few lines via CSS for
  visual consistency, drops inline images and shows every attachment as a
  thumbnail row instead. Full mode renders inline images in place and the
  unreferenced attachments as a gallery.

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

  # How many reposter faces the "Reposted by" avatar stack shows before the
  # rest collapse into a `+N` chip. Five keeps the strip to one tidy line even
  # on a phone (5 × 20px avatars, overlapped, plus the chip and the sentence).
  @repost_stack_cap 5

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
    {body_html, truncated?} =
      case assigns.mode do
        :full -> {VutuvWeb.Markdown.render_post(assigns.post.body, assigns.post.images), false}
        :preview -> VutuvWeb.Markdown.render_preview(assigns.post.body, [])
      end

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
      |> assign(:truncated?, truncated?)
      |> assign(:restricted?, Posts.restricted?(assigns.post))
      |> assign(:permalink, Posts.path(assigns.post))
      |> assign(:gallery, gallery(assigns.post, assigns.mode))
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
      |> assign(:body_length_hint, preview_length_hint(assigns))
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
    <.post_card_body
      surface={@surface}
      class={@class}
      post={@post}
      mode={@mode}
      body_html={@body_html}
      body_id={@body_id}
      body_length_hint={@body_length_hint}
      truncated?={@truncated?}
      restricted?={@restricted?}
      permalink={@permalink}
      gallery={@gallery}
      edited?={@edited?}
      author?={@author?}
      reporter?={@reporter?}
      viewer_follow={@viewer_follow}
      frozen?={@frozen?}
      reposted_by={@reposted_by}
      reposters={@reposters}
      reply_banner={@reply_banner}
      conn_or_socket={@conn_or_socket}
      actions_id={@actions_id}
      menu_id={@menu_id}
      report_menu_id={@report_menu_id}
      time_id={@time_id}
      engagement={@engagement}
      viewer_id={@viewer_id}
    />
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
          <span class="text-xs text-slate-500 dark:text-slate-400">
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

  attr(:surface, :atom, required: true)
  attr(:class, :string, default: nil)
  attr(:post, :any, required: true)
  attr(:mode, :atom, required: true)
  attr(:body_html, :any, required: true)
  attr(:body_id, :string, required: true)
  attr(:body_length_hint, :any, default: nil)
  attr(:truncated?, :boolean, required: true)
  attr(:restricted?, :boolean, required: true)
  attr(:permalink, :string, required: true)
  attr(:gallery, :list, required: true)
  attr(:edited?, :boolean, required: true)
  attr(:author?, :boolean, required: true)
  attr(:reporter?, :boolean, required: true)
  attr(:viewer_follow, :any, default: nil)
  attr(:frozen?, :boolean, required: true)
  attr(:reposted_by, :any, required: true)
  attr(:reposters, :list, required: true)
  attr(:reply_banner, :any, required: true)
  attr(:conn_or_socket, :any, required: true)
  attr(:actions_id, :string, required: true)
  attr(:menu_id, :string, required: true)
  attr(:report_menu_id, :string, required: true)
  attr(:time_id, :string, required: true)
  attr(:engagement, :any, default: nil)
  attr(:viewer_id, :any, default: nil)

  defp post_card_body(assigns) do
    ~H"""
    <.card :if={@surface == :card} class={@class}>
      {render_post_card_inner(assigns)}
    </.card>
    <div :if={@surface == :flat} class={@class}>
      {render_post_card_inner(assigns)}
    </div>
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
          <p
            class="mb-3 flex items-center gap-1.5 text-xs font-semibold text-slate-500 dark:text-slate-400"
            data-reply-banner="parent"
          >
            <.icon_reply class="h-4 w-4" />
            <.link href={parent_path} class="hover:text-brand-700">
              {gettext("Replying to %{handle}", handle: handle(parent_author))}
            </.link>
          </p>
        <% {:author_only, parent_author} -> %>
          <p
            class="mb-3 flex items-center gap-1.5 text-xs font-semibold text-slate-500 dark:text-slate-400"
            data-reply-banner="author-only"
          >
            <.icon_reply class="h-4 w-4" />
            <.link href={~p"/#{parent_author}"} class="hover:text-brand-700">
              {gettext("Reply to a now-deleted post by %{handle}", handle: handle(parent_author))}
            </.link>
          </p>
        <% :gone -> %>
          <p
            class="mb-3 flex items-center gap-1.5 text-xs font-semibold text-slate-500 dark:text-slate-400"
            data-reply-banner="gone"
          >
            <.icon_reply class="h-4 w-4" />
            {gettext("Reply to a deleted post")}
          </p>
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
          <div class="flex flex-wrap items-baseline gap-x-2">
            <.link
              href={~p"/#{@post.user}"}
              class="font-semibold text-slate-900 hover:text-brand-700 dark:text-white"
            >
              {full_name(@post.user)}
            </.link>
            <.link href={@permalink} class="text-sm text-slate-500 hover:text-brand-700">
              <.post_time id={@time_id} at={@post.inserted_at} />
            </.link>
            <span :if={@edited?} class="text-xs text-slate-500">{gettext("edited")}</span>
            <span
              :if={@restricted?}
              title={gettext("Limited audience")}
              class="text-xs text-slate-500"
              aria-label={gettext("Limited audience")}
            >
              🔒
            </span>
          </div>

          <%!-- Full mode: the whole body, no clamp. --%>
          <div
            :if={@mode == :full and @post.body != ""}
            class="markdown mt-2 text-slate-800 dark:text-slate-200"
          >
            {@body_html}
          </div>

          <%!-- Preview mode: the body is clamped to six lines and paired with a
          "Read more" link carrying the full post's length. The PostPreviewClamp
          hook (live pages) / the data-post-preview sweep (dead pages) reveals the
          link whenever the body is really cut — either the source was truncated
          server-side (@truncated?, shown with no JS too) or a short post still
          overflows the CSS line-clamp, which the server can't know because
          wrapping is width- and font-dependent. With JS off a css-only clamp
          keeps the native line-clamp ellipsis and no link, which is fine. --%>
          <div
            :if={@mode == :preview and @post.body != ""}
            id={@body_id}
            phx-hook="PostPreviewClamp"
            data-post-preview
            data-server-truncated={to_string(@truncated?)}
            class="mt-2"
          >
            <div class="markdown line-clamp-6 text-slate-800 dark:text-slate-200" data-clamp-body>
              {@body_html}
            </div>
            <.link
              href={@permalink}
              data-read-more
              class={[
                "mt-1 inline-flex items-baseline gap-1.5 text-sm font-semibold text-brand-600 hover:text-brand-700",
                not @truncated? && "hidden"
              ]}
            >
              {gettext("Read more")}
              <span
                :if={@body_length_hint}
                class="text-xs font-normal text-slate-500 dark:text-slate-400"
              >
                · {@body_length_hint}
              </span>
            </.link>
          </div>

          <%= if @mode == :preview do %>
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
          <% else %>
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

          <div :if={@post.tags != []} class="mt-3 flex flex-wrap gap-2">
            <.chip :for={tag <- @post.tags} navigate={~p"/tags/#{tag}"}>{tag.name}</.chip>
          </div>

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

        <%!-- The author's quiet ⋯ menu, on every rendering of their post. --%>
        <div :if={@author?} class="shrink-0">
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

        <%!-- Everyone else gets the same quiet ⋯ menu with the Report action —
        plus a Mute toggle when the viewer follows this author, so an annoying
        post can be silenced straight from the feed. Mute keeps the follow (and
        any vernetzt status); it only drops the author's posts from your feed. --%>
        <div :if={@reporter?} class="shrink-0">
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
      class="mb-3 flex items-center gap-2 text-xs font-semibold text-slate-500 dark:text-slate-400"
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

  # The "how long is the whole post" hint shown beside a preview's "Read more"
  # link: the full body's word count, formatted (never a bare integer) and
  # pluralised. `nil` in full mode (the whole post is on screen already) and for
  # a bodyless image-only post (no link renders). Counts the full source, not the
  # possibly-truncated snippet, so it answers "how long is the whole post".
  defp preview_length_hint(%{mode: :preview, post: %{body: body}}) when body != "" do
    count = body |> String.split() |> length()

    ngettext(
      "%{formatted} word total",
      "%{formatted} words total",
      count,
      formatted: compact_count(count)
    )
  end

  defp preview_length_hint(_), do: nil

  # Reply system messages name the account handle, never the clear name.
  defp handle(%User{username: username}), do: "@" <> username

  # Full mode: attachments the body references inline render in place; the
  # rest form the gallery. Preview mode handles images separately (thumbs).
  defp gallery(post, :preview), do: post.images

  defp gallery(post, :full) do
    Enum.reject(post.images, &PostImage.referenced_in?(&1, post.body))
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
      class="-mx-2 mt-3 flex items-center justify-between gap-2 text-slate-500 dark:text-slate-400"
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
        "text-slate-500 dark:text-slate-400"
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
        if(@active?, do: @active_class, else: "text-slate-500 dark:text-slate-400")
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
