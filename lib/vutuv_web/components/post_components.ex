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

  alias Vutuv.Posts
  alias Vutuv.Posts.PostImage

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
      "timeline entry id (\"post-<id>\" / \"repost-<id>\") — keeps embedded LiveView ids " <>
        "unique when the same post renders more than once on a page"
  )

  attr(:class, :string, default: nil)

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
      |> assign(:restricted?, assigns.post.denials != [])
      |> assign(:permalink, Posts.path(assigns.post))
      |> assign(:gallery, gallery(assigns.post, assigns.mode))
      # Both ids derive from the timeline entry when there is one: the same
      # post can render twice on a page (original + repost), and DOM ids
      # must stay unique.
      |> assign(:actions_id, "post-actions-#{assigns.entry_id || assigns.post.id}")
      |> assign(:menu_id, "post-menu-#{assigns.entry_id || assigns.post.id}")
      |> assign(
        :author?,
        assigns.viewer != nil && assigns.viewer.id == assigns.post.user_id
      )
      |> assign(
        :edited?,
        NaiveDateTime.diff(assigns.post.updated_at, assigns.post.inserted_at) > 60
      )

    ~H"""
    <.card :if={@surface == :card} class={@class}>
      <.post_card_body
        post={@post}
        mode={@mode}
        body_html={@body_html}
        truncated?={@truncated?}
        restricted?={@restricted?}
        permalink={@permalink}
        gallery={@gallery}
        edited?={@edited?}
        author?={@author?}
        reposted_by={@reposted_by}
        conn_or_socket={@conn_or_socket}
        actions_id={@actions_id}
        menu_id={@menu_id}
      />
    </.card>
    <div :if={@surface == :flat} class={@class}>
      <.post_card_body
        post={@post}
        mode={@mode}
        body_html={@body_html}
        truncated?={@truncated?}
        restricted?={@restricted?}
        permalink={@permalink}
        gallery={@gallery}
        edited?={@edited?}
        author?={@author?}
        reposted_by={@reposted_by}
        conn_or_socket={@conn_or_socket}
        actions_id={@actions_id}
        menu_id={@menu_id}
      />
    </div>
    """
  end

  attr(:post, :any, required: true)
  attr(:mode, :atom, required: true)
  attr(:body_html, :any, required: true)
  attr(:truncated?, :boolean, required: true)
  attr(:restricted?, :boolean, required: true)
  attr(:permalink, :string, required: true)
  attr(:gallery, :list, required: true)
  attr(:edited?, :boolean, required: true)
  attr(:author?, :boolean, required: true)
  attr(:reposted_by, :any, required: true)
  attr(:conn_or_socket, :any, required: true)
  attr(:actions_id, :string, required: true)
  attr(:menu_id, :string, required: true)

  defp post_card_body(assigns) do
    ~H"""
    <div>
      <p
        :if={@reposted_by}
        class="mb-3 flex items-center gap-1.5 text-xs font-semibold text-slate-500 dark:text-slate-400"
        data-reposted-by={@reposted_by.id}
      >
        <svg class="h-4 w-4" fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            d="M19.5 12c0-1.232-.046-2.453-.138-3.662a4.006 4.006 0 0 0-3.7-3.7 48.678 48.678 0 0 0-7.324 0 4.006 4.006 0 0 0-3.7 3.7c-.017.22-.032.441-.046.662M19.5 12l3-3m-3 3-3-3m-12 3c0 1.232.046 2.453.138 3.662a4.006 4.006 0 0 0 3.7 3.7 48.656 48.656 0 0 0 7.324 0 4.006 4.006 0 0 0 3.7-3.7c.017-.22.032-.441.046-.662M4.5 12l3 3m-3-3-3 3"
          />
        </svg>
        <.link href={~p"/#{@reposted_by}"} class="hover:text-brand-700">
          {gettext("Reposted by %{name}", name: full_name(@reposted_by))}
        </.link>
      </p>

      <div class="flex items-start gap-3">
        <.link href={~p"/#{@post.user}"} class="shrink-0">
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
            <.link href={@permalink} class="text-sm text-slate-500 hover:text-brand-700">
              <time datetime={NaiveDateTime.to_iso8601(@post.inserted_at)}>
                {Calendar.strftime(@post.inserted_at, "%Y-%m-%d %H:%M")}
              </time>
            </.link>
            <span :if={@edited?} class="text-xs text-slate-400">{gettext("edited")}</span>
            <span
              :if={@restricted?}
              title={gettext("Limited audience")}
              class="text-xs text-slate-400"
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
            <.link :if={length(@post.images) == 1} href={@permalink} class="mt-3 block">
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
              <.link :for={image <- @post.images} href={@permalink} class="block">
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
            session: %{"post_id" => @post.id, "id" => @actions_id}
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
      </div>
    </div>
    """
  end

  # Full mode: attachments the body references inline render in place; the
  # rest form the gallery. Preview mode handles images separately (thumbs).
  defp gallery(post, :preview), do: post.images

  defp gallery(post, :full) do
    Enum.reject(post.images, &String.contains?(post.body, "/post_images/#{&1.token}/"))
  end
end
