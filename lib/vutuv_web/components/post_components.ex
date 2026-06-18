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
  alias Vutuv.Posts.Post
  alias Vutuv.Posts.PostImage
  alias Vutuv.Posts.PostReply

  attr(:post, :any, required: true, doc: "preloaded %Vutuv.Posts.Post{}")
  attr(:viewer, :any, default: nil)
  attr(:mode, :atom, default: :preview, values: [:preview, :full])

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
      |> assign(:menu_id, "post-menu-#{assigns.entry_id || assigns.post.id}")
      |> assign(:report_menu_id, "post-report-#{assigns.entry_id || assigns.post.id}")
      |> assign(:time_id, "post-time-#{assigns.entry_id || assigns.post.id}")
      |> assign(:author?, Posts.author?(assigns.post, assigns.viewer))
      |> assign(
        :reporter?,
        match?(%User{}, assigns.viewer) and not Posts.author?(assigns.post, assigns.viewer)
      )
      |> assign(:frozen?, assigns.post.frozen_at != nil)
      |> assign(:reply_banner, reply_banner(assigns.post))
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
      frozen?={@frozen?}
      reposted_by={@reposted_by}
      reply_banner={@reply_banner}
      conn_or_socket={@conn_or_socket}
      actions_id={@actions_id}
      menu_id={@menu_id}
      report_menu_id={@report_menu_id}
      time_id={@time_id}
      engagement={@engagement}
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
  attr(:frozen?, :boolean, required: true)
  attr(:reposted_by, :any, required: true)
  attr(:reply_banner, :any, required: true)
  attr(:conn_or_socket, :any, required: true)
  attr(:actions_id, :string, required: true)
  attr(:menu_id, :string, required: true)
  attr(:report_menu_id, :string, required: true)
  attr(:time_id, :string, required: true)
  attr(:engagement, :any, default: nil)

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
              <%!-- Stored timestamps are naive UTC; the trailing "Z" lets the
              LocalTime pass (LiveView hook on live pages, the DOMContentLoaded
              sweep on dead ones) rewrite it into the viewer's timezone. The
              server-rendered text is the no-JS fallback. --%>
              <time
                id={@time_id}
                phx-hook="LocalTime"
                data-localtime
                datetime={NaiveDateTime.to_iso8601(@post.inserted_at) <> "Z"}
                title={NaiveDateTime.to_iso8601(@post.inserted_at) <> "Z"}
              >
                {Calendar.strftime(@post.inserted_at, "%Y-%m-%d %H:%M")}
              </time>
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

          <%!-- The live action bar (like / repost / bookmark + counters): its
          own embedded LiveView per card, so the counters tick on dead pages
          too. The id derives from the timeline entry, not the post — the same
          post can render twice on one page (original + repost). --%>
          {live_render(@conn_or_socket, VutuvWeb.PostLive.Actions,
            id: @actions_id,
            session: %{"post_id" => @post.id, "id" => @actions_id, "engagement" => @engagement}
          )}
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

        <%!-- Everyone else gets the same quiet ⋯ menu with the Report action:
        out of the way until needed, easy to find when it is. --%>
        <div :if={@reporter?} class="shrink-0">
          <.card_menu id={@report_menu_id}>
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
  # %Ecto.Association.NotLoaded{}.
  defp reply_banner(%Post{reply_ref: %PostReply{} = ref}) do
    cond do
      match?(%Post{}, ref.parent_post) ->
        {:parent, ref.parent_post.user, Posts.path(ref.parent_post)}

      match?(%User{}, ref.parent_author) ->
        {:author_only, ref.parent_author}

      true ->
        :gone
    end
  end

  defp reply_banner(_post), do: nil

  # Reply system messages name the account handle, never the clear name.
  defp handle(%User{active_slug: slug}), do: "@" <> slug

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
end
