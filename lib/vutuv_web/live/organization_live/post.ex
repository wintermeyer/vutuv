defmodule VutuvWeb.OrganizationLive.Post do
  @moduledoc """
  The permalink of a post published in an organization's name
  (`/organizations/:slug/posts/:id`, issue #1334). Embedded via `live_render`
  from `VutuvWeb.OrganizationController`, like the organization page itself.

  The way back to the page that published it, and then the post **with its
  conversation** — the answers written here and the ones written on other
  networks, woven together in time order.

  That conversation is `VutuvWeb.PostLive.Thread`, nested by `live_render`, and
  not a second rendering of one: the member permalink has grown a windowed thread
  with expanders, per-card action bars on one socket, and the hosting of the
  remote cards' own acts, and a page's post now collects exactly the same things
  (issue #1336 opened local replies to it). A page's post used to render its own
  post card plus a read-only list of remote replies, which cost this page every
  one of those and, less obviously, offered a ⋯ menu whose `phx-click` no handler
  here answered — the takedown a publisher gained in #1417 was on a card whose
  host could not perform it.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.OrganizationComponents, only: [organization_logo: 1]

  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias VutuvWeb.Live.InitAssigns

  @impl true
  def mount(_params, session, socket) do
    socket = InitAssigns.assign_embedded(socket, session)
    organization = Organizations.get_organization!(session["organization_id"])

    # Resolved again on the socket rather than handed over in the session map:
    # the controller's copy authenticated one HTTP request, and the live view
    # re-asks who the viewer is on connect (`InitAssigns`), so what they may see
    # is re-decided with it.
    post =
      Posts.get_organization_post(organization, session["post_id"], socket.assigns.current_user)

    if post do
      {:ok,
       socket
       |> assign(:organization, organization)
       |> assign(:post, post)
       |> assign(:formats?, Organizations.agent_visible?(organization))
       # Carried through to the nested thread rather than left to its default:
       # the conversation scrolls itself to the permalinked post, and the
       # link-preview browser renders from the top, so a jump here stores a
       # blank preview (issue #1033) — the trap the member permalink already
       # avoids.
       |> assign(:auto_scroll?, session["auto_scroll"] != false)
       |> assign(:page_title, organization.name)}
    else
      # The controller already refused an id that does not resolve, so reaching
      # here means the answer changed between that request and this connect —
      # a publisher role withdrawn while the page was open, on a held post.
      {:ok, push_navigate(socket, to: Organizations.canonical_path(organization))}
    end
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@post} class="mx-auto max-w-2xl py-6">
      <.link
        navigate={Organizations.canonical_path(@organization)}
        class="flex items-center gap-3 text-sm font-semibold text-slate-600 hover:text-brand-700 dark:text-slate-400 dark:hover:text-brand-300"
      >
        <.organization_logo organization={@organization} class="h-8 w-8" />
        {@organization.name}
      </.link>

      <%!-- The post and everything answering it, from `VutuvWeb.PostLive.Thread`
      — the same conversation the member permalink shows, nested here as its own
      LiveView so the expanders, the per-card action bars and the remote cards'
      takedown controls all have the host they need. Its dead render is thrown
      away and re-mounted on connect like any nested child, and it resolves the
      viewer from the cookie session itself, so this page hands it the post id
      and the one thing it cannot work out for itself: whether the reader is a
      person or the screenshot browser. --%>
      <div class="mt-4">
        {live_render(@socket, VutuvWeb.PostLive.Thread,
          id: "organization-post-thread",
          session: %{"post_id" => @post.id, "auto_scroll" => @auto_scroll?}
        )}
      </div>

      <%!-- The agent-format siblings of this permalink. Shown only when they
      actually serve: a page that is not active + `geo?` 404s them, and a `.md`
      chip that leads to a 404 is worse than no chip. --%>
      <.other_formats_card
        :if={@formats?}
        id="organization-post-formats"
        base_path={Vutuv.Posts.path(@post)}
        locale={@locale}
        class="mt-6"
      />
    </div>
    """
  end
end
