defmodule VutuvWeb.OrganizationLive.Post do
  @moduledoc """
  The permalink of a post published in an organization's name
  (`/organizations/:slug/posts/:id`, issue #1334). Embedded via `live_render`
  from `VutuvWeb.OrganizationController`, like the organization page itself.

  Deliberately just the post and the way back to the page that published it.
  There is no conversation below it because an organization post cannot be
  answered yet (`Vutuv.Posts.check_reply_allowed/2` refuses): everything a reply
  sets in motion is member-shaped, and an organization has no inbox to be told
  about one until issue #1336 gives it a reading side.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.OrganizationComponents, only: [organization_logo: 1]
  import VutuvWeb.PostComponents, only: [post_card: 1]

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
    </div>
    """
  end
end
