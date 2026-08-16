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

  **Two card shapes, because the feed has two kinds of entry.** Three of its
  four sources carry a vutuv post; the fourth (accounts the page follows on
  other networks) carries a cached remote post and a `nil` post, so a page that
  followed one address out there 500ed this whole view until the branch below
  existed (issue #1482) — the same split `VutuvWeb.PostLive.Feed` and the tag
  timeline make.

  Embedded via `live_render` from `VutuvWeb.OrganizationController`, which gates
  it before this ever mounts.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.OrganizationComponents, only: [manage_header: 1]
  import VutuvWeb.PostComponents, only: [post_card: 1, remote_post_card: 1]

  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias VutuvWeb.Live.InitAssigns
  alias VutuvWeb.Live.RemotePostActions

  @impl true
  def mount(_params, session, socket) do
    socket = InitAssigns.assign_embedded(socket, session)
    organization = Organizations.get_organization!(session["organization_id"])

    {:ok,
     socket
     |> assign(:organization, organization)
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

  # Reporting a cached post from another network is the reader's own act, like
  # the like and the bookmark under the card: it deletes our copy for everybody
  # here, so the row leaves in the same round trip rather than sitting there
  # until the next load.
  def handle_event("report-remote-post", %{"id" => id}, socket) do
    RemotePostActions.report(socket, id, &drop_remote_entry(&1, id))
  end

  defp drop_remote_entry(socket, remote_post_id) do
    update(socket, :entries, fn entries ->
      Enum.reject(entries, &(&1[:remote_post] && &1.remote_post.id == remote_post_id))
    end)
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl py-6">
      <.manage_header
        organization={@organization}
        active={:feed}
        viewer={@current_user}
      />

      <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">{gettext("Feed")}</h1>
      <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
        {gettext("What the members and organizations this page follows have published. Liking or saving something here is done from your own account, not the page's.")}
      </p>

      <p :if={@entries == []} class="mt-6 text-sm text-slate-600 dark:text-slate-400">
        {gettext("Nothing here yet. This page does not follow anyone, or nobody it follows has published.")}
      </p>

      <div :if={@entries != []} class="mt-6 space-y-4">
        <%= for entry <- @entries do %>
          <%= if Posts.remote_feed_entry?(entry) do %>
            <%!-- A post by an account the page follows out there — the fourth
            source, and one that carries no vutuv post at all (`entry.post` is
            nil). It wears the same remote card every other surface draws,
            inside the card shell `<.post_card surface={:card}>` renders for
            the local half beside it. No Mute: that lever belongs to the
            reader's OWN follow, and this feed is built from the page's follow
            graph alone — muting here would leave the card exactly where it is.
            The page's subscriptions are taken back on the Follows tab. --%>
            <.card>
              <.remote_post_card
                live?
                remote_post={entry.remote_post}
                images={entry[:images] || []}
                marks={entry[:marks]}
                viewer={@current_user}
                mute?={false}
              />
            </.card>
          <% else %>
            <.post_card
              entry_id={entry.id}
              post={entry.post}
              viewer={@current_user}
              conn_or_socket={@socket}
              mode={:preview}
            />
          <% end %>
        <% end %>
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
