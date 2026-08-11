defmodule VutuvWeb.OrganizationLive.Activity do
  @moduledoc """
  What happened to an organization page (`/organizations/:slug/activity`,
  issue #1336): who followed it, and who liked or reposted what it published.

  **One read marker for the whole team.** Opening this page stamps
  `organizations.activity_read_at`, and it is stamped for everybody — "read"
  here means somebody read it, never that everybody did. That is the model the
  issue asks for, and it is a different one rather than a wider one, which is
  why it is a column on the page instead of a row per member.

  Open to the whole team (`can_manage?/2`) rather than to publishers alone.
  Deviating from the issue's "everyone who may act as it" on purpose: this is
  news *about* the page, not speaking *for* it, and an owner who has not
  granted themselves `publisher` would otherwise be locked out of their own
  page's activity.

  Embedded via `live_render` from `VutuvWeb.OrganizationController`, which
  gates it before this ever mounts.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.OrganizationComponents, only: [manage_header: 1]
  import VutuvWeb.UserHelpers, only: [full_name: 1]

  alias Vutuv.Organizations
  alias Vutuv.Posts
  alias VutuvWeb.Live.InitAssigns

  @impl true
  def mount(_params, session, socket) do
    socket = InitAssigns.assign_embedded(socket, session)
    organization = Organizations.get_organization!(session["organization_id"])

    # The marker is read BEFORE it is stamped, or the page would clear its own
    # "new" marks before drawing them and nothing would ever look unread.
    marker = organization.activity_read_at
    if connected?(socket), do: Organizations.mark_activity_read(organization)

    {:ok,
     socket
     |> assign(:organization, organization)
     |> assign(:owner?, Organizations.owner?(organization, socket.assigns.current_user))
     |> assign(:marker, marker)
     |> assign(:page_title, gettext("Activity – %{name}", name: organization.name))
     |> load_activity(0)}
  end

  defp load_activity(socket, offset) do
    page = Organizations.activity_page(socket.assigns.organization, offset: offset)
    existing = if offset == 0, do: [], else: socket.assigns.entries

    socket
    |> assign(:entries, existing ++ page.entries)
    |> assign(:more?, page.more?)
    |> assign(:offset, page.next_offset)
  end

  @impl true
  def handle_event("load-more", _params, socket),
    do: {:noreply, load_activity(socket, socket.assigns.offset)}

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  # Whether this entry arrived after the team last looked. Drives the quiet
  # "new" mark; a page nobody has opened yet has a nil marker, so everything
  # on it is new, which is the honest answer.
  defp new?(_entry, nil), do: true
  defp new?(%{at: at}, marker), do: NaiveDateTime.compare(at, marker) == :gt

  defp line(%{kind: "follow"} = entry),
    do: gettext("%{name} follows this page.", name: full_name(entry.actor))

  defp line(%{kind: "post_like"} = entry),
    do: gettext("%{name} liked a post.", name: full_name(entry.actor))

  defp line(%{kind: "post_repost"} = entry),
    do: gettext("%{name} reposted a post.", name: full_name(entry.actor))

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl py-6">
      <.manage_header organization={@organization} active={:activity} owner?={@owner?} manage?={true} />

      <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">{gettext("Activity")}</h1>
      <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
        {gettext("What happened to this page. Everyone on the team sees the same list, and opening it marks it read for all of you.")}
      </p>

      <.card class="mt-6">
        <p :if={@entries == []} class="text-sm text-slate-600 dark:text-slate-400">
          {gettext("Nothing has happened yet.")}
        </p>

        <ul :if={@entries != []} class="divide-y divide-slate-100 dark:divide-slate-800">
          <li :for={entry <- @entries} id={entry.id} class="flex items-start gap-3 py-3">
            <.link navigate={"/#{entry.actor.username}"} class="shrink-0">
              <.avatar user={entry.actor} size="sm" shape="circle" />
            </.link>

            <div class="min-w-0 flex-1">
              <p class="text-sm text-slate-800 dark:text-slate-200">
                {line(entry)}
                <span
                  :if={new?(entry, @marker)}
                  data-activity-new
                  class="ml-1 rounded-full bg-brand-100 px-2 py-0.5 text-xs font-semibold text-brand-700 dark:bg-brand-800 dark:text-brand-100"
                >
                  {gettext("New")}
                </span>
              </p>

              <.link
                :if={entry.post}
                navigate={Posts.path(entry.post)}
                class="mt-0.5 line-clamp-1 block text-sm text-slate-600 hover:text-brand-700 dark:text-slate-400 dark:hover:text-brand-300"
              >
                {VutuvWeb.Markdown.to_plain_text(entry.post.body)}
              </.link>

              <.local_time
                at={entry.at}
                id={"activity-time-#{entry.id}"}
                class="mt-0.5 block text-xs text-slate-600 dark:text-slate-400"
              />
            </div>
          </li>
        </ul>

        <div :if={@more?} class="mt-4 text-center">
          <.button variant="secondary" phx-click="load-more" id="load-more-activity">
            {gettext("Load more")}
          </.button>
        </div>
      </.card>
    </div>
    """
  end
end
