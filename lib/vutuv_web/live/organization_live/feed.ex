defmodule VutuvWeb.OrganizationLive.Feed do
  @moduledoc """
  The feed a page reads (`/organizations/:slug/feed`, issue #1336) — what the
  members and pages it follows have published. This is the direction #1334 and
  #1335 deliberately left out: a page that can publish but not read is
  one-directional, and a feed is derived from follows, so it could not exist
  before a page could follow.

  **Publishers only**, unlike the activity list beside it, and the difference is
  the point: activity is news *about* the page, which the whole team may read,
  while this is the page's own reading — part of speaking for it.

  **The action bar under each card belongs to the acting member, not to the
  page.** A page has no likes or bookmarks of its own yet, so a bar bound to it
  would have no owner; a like here is the person's, from their own account. What
  the viewer never does is widen the feed: its contents come from the page's
  follow graph alone, so two publishers reading it see the same posts.

  Embedded via `live_render` from `VutuvWeb.OrganizationController`, which gates
  it before this ever mounts.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.OrganizationComponents, only: [manage_header: 1]
  import VutuvWeb.PostComponents, only: [post_card: 1]

  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias VutuvWeb.Live.InitAssigns

  @impl true
  def mount(_params, session, socket) do
    socket = InitAssigns.assign_embedded(socket, session)
    organization = Organizations.get_organization!(session["organization_id"])

    {:ok,
     socket
     |> assign(:organization, organization)
     |> assign(:owner?, Organizations.owner?(organization, socket.assigns.current_user))
     |> assign(:page_title, gettext("Feed – %{name}", name: organization.name))
     |> load_feed(nil)}
  end

  defp load_feed(socket, cursor) do
    page =
      Posts.organization_feed_page(socket.assigns.organization,
        cursor: cursor,
        viewer: socket.assigns.current_user
      )

    existing = if cursor, do: socket.assigns.entries, else: []

    socket
    |> assign(:entries, existing ++ page.entries)
    |> assign(:more?, page.more?)
    |> assign(:cursor, page.next_cursor)
  end

  @impl true
  def handle_event("load-more", _params, socket),
    do: {:noreply, load_feed(socket, socket.assigns.cursor)}

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl py-6">
      <.manage_header
        organization={@organization}
        active={:feed}
        owner?={@owner?}
        manage?={true}
        publisher?={true}
      />

      <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">{gettext("Feed")}</h1>
      <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
        {gettext("What the members and organizations this page follows have published. Liking or saving something here is done from your own account, not the page's.")}
      </p>

      <p :if={@entries == []} class="mt-6 text-sm text-slate-600 dark:text-slate-400">
        {gettext("Nothing here yet. This page does not follow anyone, or nobody it follows has published.")}
      </p>

      <div :if={@entries != []} class="mt-6 space-y-4">
        <.post_card
          :for={entry <- @entries}
          entry_id={entry.id}
          post={entry.post}
          viewer={@current_user}
          conn_or_socket={@socket}
          mode={:preview}
        />
      </div>

      <div :if={@more?} class="mt-6 text-center">
        <.button variant="secondary" phx-click="load-more" id="load-more-feed">
          {gettext("Load more")}
        </.button>
      </div>
    </div>
    """
  end
end
