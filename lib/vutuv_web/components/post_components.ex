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

    assigns =
      assigns
      |> assign(:body_html, body_html)
      |> assign(:truncated?, truncated?)
      |> assign(:restricted?, Posts.restricted?(assigns.post))
      |> assign(:permalink, Posts.path(assigns.post))
      |> assign(:gallery, gallery(assigns.post, assigns.mode))
      # Both ids derive from the timeline entry when there is one: the same
      # post can render twice on a page (original + repost), and DOM ids
      # must stay unique.
      |> assign(:actions_id, "post-actions-#{assigns.entry_id || assigns.post.id}")
      # The action bar's acting viewer id (nil = logged-out / public preview).
      # On a LiveView host the inline component is handed this directly; on a
      # dead page the standalone bar reads it from the session instead. nil (not
      # the `false` an `&&` would yield) — Posts.post_engagement/2 only accepts a
      # user id or nil.
      |> assign(:viewer_id, if(user?, do: viewer.id))
      |> assign(:menu_id, "post-menu-#{assigns.entry_id || assigns.post.id}")
      |> assign(:report_menu_id, "post-report-#{assigns.entry_id || assigns.post.id}")
      |> assign(:time_id, "post-time-#{assigns.entry_id || assigns.post.id}")
      |> assign(:author?, Posts.author?(assigns.post, viewer))
      |> assign(:reporter?, user? and not Posts.author?(assigns.post, viewer))
      |> assign(:frozen?, assigns.post.frozen_at != nil)
      |> assign(:reply_banner, reply_banner(assigns.post, assigns.show_reply_banner))
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

  attr(:surface, :atom, required: true)
  attr(:class, :string, default: nil)
  attr(:post, :any, required: true)
  attr(:mode, :atom, required: true)
  attr(:body_html, :any, required: true)
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

      <p
        :if={@reposted_by}
        class="mb-3 flex items-center gap-1.5 text-xs font-semibold text-slate-500 dark:text-slate-400"
        data-reposted-by={@reposted_by.id}
      >
        <.icon_repost class="h-4 w-4" />
        <.link href={~p"/#{@reposted_by}"} class="hover:text-brand-700">
          {gettext("Reposted by %{name}", name: full_name(@reposted_by))}
        </.link>
      </p>

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
              <.local_time id={@time_id} at={@post.inserted_at} />
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

          <div
            :if={@post.body != ""}
            class={["markdown mt-2 text-slate-800 dark:text-slate-200", @mode == :preview && "line-clamp-5"]}
          >
            {@body_html}
          </div>

          <.link
            :if={@mode == :preview && @truncated?}
            href={@permalink}
            class="mt-1 inline-block text-sm font-semibold text-brand-600 hover:text-brand-700"
          >
            {gettext("Read more")}
          </.link>

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
