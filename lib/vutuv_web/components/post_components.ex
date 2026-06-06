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
  attr(:class, :string, default: nil)
  slot(:menu, doc: "owner actions, rendered top-right")

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
      |> assign(
        :edited?,
        NaiveDateTime.diff(assigns.post.updated_at, assigns.post.inserted_at) > 60
      )

    ~H"""
    <.card class={@class}>
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
            <div :if={@post.images != []} class="mt-3 flex flex-wrap gap-2">
              <.link :for={image <- @post.images} href={@permalink} class="block">
                <img
                  src={PostImage.url(image, "thumb")}
                  alt={image.alt}
                  width="320"
                  height="320"
                  loading="lazy"
                  class="h-24 w-24 rounded-lg object-cover ring-1 ring-slate-200 dark:ring-slate-800"
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
        </div>

        <div :if={@menu != []} class="shrink-0">
          {render_slot(@menu)}
        </div>
      </div>
    </.card>
    """
  end

  # Full mode: attachments the body references inline render in place; the
  # rest form the gallery. Preview mode handles images separately (thumbs).
  defp gallery(post, :preview), do: post.images

  defp gallery(post, :full) do
    Enum.reject(post.images, &String.contains?(post.body, "/post_images/#{&1.token}/"))
  end
end
