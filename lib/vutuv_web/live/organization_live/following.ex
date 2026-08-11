defmodule VutuvWeb.OrganizationLive.Following do
  @moduledoc """
  What a page follows (`/organizations/:slug/following`, issue #1336) — the
  list behind the feed beside it, and the only place its team can take a
  subscription back.

  **Publishers only**, like the feed and for the same reason: this is the
  page's own reading, which is part of speaking for it, not news about it.

  Deliberately **not public**, unlike a member's Following page. What a page
  reads is working material — which competitors and topics a company watches
  says more about its plans than a member's reading list says about theirs —
  and nothing in #1336 asks for it to be on show. Making it public later is an
  easy step; taking it back would not be.

  Embedded via `live_render` from `VutuvWeb.OrganizationController`, which gates
  it before this ever mounts.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.OrganizationComponents,
    only: [manage_header: 1, organization_logo: 1, organization_location: 1]

  import VutuvWeb.UserHelpers, only: [full_name: 1]

  alias Vutuv.Accounts.User
  alias Vutuv.Organizations
  alias Vutuv.Organizations.Organization
  alias Vutuv.Social
  alias Vutuv.Tags
  alias VutuvWeb.Live.InitAssigns

  @impl true
  def mount(_params, session, socket) do
    socket = InitAssigns.assign_embedded(socket, session)
    organization = Organizations.get_organization!(session["organization_id"])

    {:ok,
     socket
     |> assign(:organization, organization)
     |> assign(:owner?, Organizations.owner?(organization, socket.assigns.current_user))
     |> assign(:page_title, gettext("Following – %{name}", name: organization.name))
     |> load_following()}
  end

  defp load_following(socket) do
    organization = socket.assigns.organization

    socket
    |> assign(:followees, Social.organization_followees(organization))
    |> assign(:tags, Tags.organization_followed_tags(organization))
  end

  @impl true
  def handle_event("unfollow", %{"id" => follow_id}, socket) do
    organization = socket.assigns.organization

    # Scoped to this page's own edges: `organization_followees/1` only ever
    # hands out follow ids belonging to it, and the delete re-checks rather
    # than trusting the id that came back from the client.
    Social.unfollow_edge_as_organization(organization, follow_id)

    {:noreply, load_following(socket)}
  end

  def handle_event("unfollow-tag", %{"id" => tag_id}, socket) do
    Tags.unfollow_tag_as_organization(socket.assigns.organization, tag_id)
    {:noreply, load_following(socket)}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  defp followee_name(%Organization{name: name}), do: name
  defp followee_name(%User{} = user), do: full_name(user)

  defp followee_path(%Organization{} = organization),
    do: Organizations.canonical_path(organization)

  defp followee_path(%User{username: username}), do: "/#{username}"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl py-6">
      <.manage_header
        organization={@organization}
        active={:following}
        owner?={@owner?}
        manage?={true}
        publisher?={true}
      />

      <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">{gettext("Following")}</h1>
      <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
        {gettext("The members, organizations and topics this page follows. Everything here shapes its feed, and only the team can see this list.")}
      </p>

      <.card class="mt-6" id="organization-followees">
        <.section_title>{gettext("Members and organizations")}</.section_title>

        <p :if={@followees == []} class="mt-2 text-sm text-slate-600 dark:text-slate-400">
          {gettext("This page does not follow anyone yet.")}
        </p>

        <ul :if={@followees != []} class="mt-2 divide-y divide-slate-100 dark:divide-slate-800">
          <li :for={{follow_id, followee} <- @followees} class="flex items-center gap-4 py-4">
            <.link navigate={followee_path(followee)} class="shrink-0">
              <.organization_logo
                :if={match?(%Organization{}, followee)}
                organization={followee}
                class="h-12 w-12"
              />
              <.avatar :if={match?(%User{}, followee)} user={followee} size="md" shape="circle" />
            </.link>

            <div class="min-w-0 flex-1">
              <.link
                navigate={followee_path(followee)}
                class="block truncate font-semibold text-slate-900 hover:text-brand-700 dark:text-slate-100 dark:hover:text-brand-300"
              >
                {followee_name(followee)}
              </.link>
              <.organization_location
                :if={match?(%Organization{}, followee)}
                organization={followee}
                class="truncate text-sm text-slate-600 dark:text-slate-400"
              />
            </div>

            <.button
              variant="secondary"
              phx-click="unfollow"
              phx-value-id={follow_id}
              class="shrink-0"
            >
              {gettext("Unfollow")}
            </.button>
          </li>
        </ul>
      </.card>

      <.card class="mt-4" id="organization-followed-tags">
        <.section_title>{gettext("Topics")}</.section_title>

        <p :if={@tags == []} class="mt-2 text-sm text-slate-600 dark:text-slate-400">
          {gettext("This page does not follow any topics yet.")}
        </p>

        <div :if={@tags != []} class="mt-3 flex flex-wrap gap-2">
          <span :for={tag <- @tags} class="inline-flex items-center gap-1">
            <.chip navigate={~p"/tags/#{tag.slug}"}>{tag.name}</.chip>
            <button
              type="button"
              phx-click="unfollow-tag"
              phx-value-id={tag.id}
              title={gettext("Unfollow %{tag}", tag: tag.name)}
              aria-label={gettext("Unfollow %{tag}", tag: tag.name)}
              class="inline-flex h-10 w-10 items-center justify-center rounded-lg text-slate-600 hover:bg-slate-100 hover:text-rose-700 dark:text-slate-400 dark:hover:bg-slate-800 dark:hover:text-rose-300"
            >
              ✕
            </button>
          </span>
        </div>
      </.card>
    </div>
    """
  end
end
