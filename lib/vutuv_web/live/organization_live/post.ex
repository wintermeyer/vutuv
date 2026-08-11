defmodule VutuvWeb.OrganizationLive.Post do
  @moduledoc """
  The permalink of a post published in an organization's name
  (`/organizations/:slug/posts/:id`, issue #1334). Embedded via `live_render`
  from `VutuvWeb.OrganizationController`, like the organization page itself.

  The post, the way back to the page that published it, and the replies written
  on **other networks** (issue #1334 completing #1069 for pages).

  Still no vutuv conversation below it: an organization post cannot be answered
  here (`Vutuv.Posts.check_reply_allowed/2` refuses), because everything a local
  reply sets in motion is member-shaped. A remote reply is different — it
  arrives whether or not we host a thread for it, and hiding what a page's own
  post already collected would only mean the team cannot see it.

  Those cards are **read-only** here, unlike on the member thread that owns
  them: removing, reporting and the heart all belong to a person, and a page has
  nobody behind those buttons.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.PostComponents, only: [post_card: 1, remote_reply_card: 1]
  import VutuvWeb.OrganizationComponents, only: [organization_logo: 1]

  alias Vutuv.Fediverse
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
       # Replies from other networks (issue #1334, completing #1069 for pages).
       # Viewer-scoped by `list_notes/2` like the member permalink, so a reply
       # addressed to the page alone never reaches anybody else's render.
       |> assign(
         :remote_replies,
         Fediverse.list_notes([post.id], socket.assigns.current_user)[post.id] || []
       )
       |> assign(:formats?, Organizations.agent_visible?(organization))
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

      <div class="mt-4">
        <.post_card post={@post} viewer={@current_user} conn_or_socket={@socket} mode={:full} />
      </div>

      <%!-- Replies written on another network (issue #1334). Read-only here,
      like the member-facing answering page: the acts on such a card (remove,
      report, the heart) are hosted by the member thread that owns them, and a
      page has no member behind those buttons. --%>
      <div :if={@remote_replies != []} class="mt-4 space-y-3" id="organization-remote-replies">
        <.remote_reply_card :for={note <- @remote_replies} note={note} viewer={@current_user} />
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
