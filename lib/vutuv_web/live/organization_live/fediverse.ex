defmodule VutuvWeb.OrganizationLive.Fediverse do
  @moduledoc """
  The owner's switch for federating a page (`/organizations/:slug/fediverse`,
  issue #1334) — the last piece of that half, and the one that makes any of it
  reachable. Everything else refuses to answer until this is on.

  **Owner-only**, unlike the feed and the following list beside it, which
  publishers may read. Turning this on decides how the page appears on servers
  we do not run, and it cannot be fully undone — a remote server that already
  holds a copy of a post can be *asked* to forget it and no more. That is an
  owner's decision, the same class as the domains and the roles.

  Two things the page has to say plainly rather than bury, because both are
  surprising if you meet them afterwards: the handle is the address (without one
  there is nothing for anybody to follow), and leaving is not a delete.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.OrganizationComponents, only: [manage_header: 1]

  alias Vutuv.Fediverse
  alias Vutuv.Organizations
  alias VutuvWeb.Live.InitAssigns

  @impl true
  def mount(_params, session, socket) do
    socket = InitAssigns.assign_embedded(socket, session)
    organization = Organizations.get_organization!(session["organization_id"])

    {:ok,
     socket
     |> assign(:page_title, gettext("Fediverse – %{name}", name: organization.name))
     |> assign_state(organization)}
  end

  defp assign_state(socket, organization) do
    socket
    |> assign(:organization, organization)
    |> assign(:owner?, true)
    |> assign(:publisher?, Organizations.publisher?(organization, socket.assigns.current_user))
    |> assign(:federated?, Fediverse.federated?(organization))
    |> assign(:ever_federated?, Fediverse.ever_federated?(organization))
    |> assign(:enabled?, Fediverse.enabled?())
    |> assign(:remote_followers, Fediverse.organization_remote_follower_count(organization))
  end

  @impl true
  def handle_event("toggle", _params, socket) do
    organization = socket.assigns.organization
    on? = not organization.fediverse_followers?

    {:ok, organization} = Organizations.set_fediverse_opt_in(organization, on?)

    # The keypair is minted on the way in, not lazily on the first request: a
    # remote server that resolves the handle a second later must find a complete
    # actor, and generating a key inside that request would be the slowest
    # possible moment for it.
    if on?, do: Fediverse.ensure_organization_actor(organization)

    {:noreply, assign_state(socket, organization)}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl py-6">
      <.manage_header
        organization={@organization}
        active={:fediverse}
        owner?={true}
        manage?={true}
        publisher?={@publisher?}
      />

      <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">{gettext("Fediverse")}</h1>
      <%!-- The same sentence the page's own empty Fediverse card shows, from one
      msgid: the owner arrives here from that card, and a page that greeted them
      by restating the offer in different words would read as a different
      feature. It says what this does for the organization (reach past vutuv)
      before it names anything, because "federate" is a word almost nobody
      outside this protocol knows, in English or in German. --%>
      <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
        {gettext(
          "People who have no vutuv account can follow this page and read its posts, in networks like Mastodon."
        )}
      </p>

      <.card :if={!@enabled?} class="mt-6">
        <p class="text-sm text-slate-700 dark:text-slate-300">
          {gettext("This vutuv exchanges nothing with other networks, so nothing here has any effect.")}
        </p>
      </.card>

      <.card :if={@enabled? and is_nil(@organization.username)} class="mt-6" id="needs-handle">
        <.section_title>{gettext("A short @name is needed first")}</.section_title>
        <%!-- Showing the shape of the address teaches more than naming the
        concept does: everybody has seen an email address, and this is written
        the same way. --%>
        <p class="mt-2 text-sm text-slate-700 dark:text-slate-300">
          {gettext(
            "Other networks address this page as @name@%{host}, the way they address a member. So it needs a short @name of its own first. Claim one in the page settings, then come back.",
            host: VutuvWeb.Endpoint.host()
          )}
        </p>
        <.link
          navigate={~p"/organizations/#{@organization.slug}/edit"}
          class="mt-3 inline-block text-sm font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
        >
          {gettext("Page settings")}
        </.link>
      </.card>

      <.card :if={@enabled? and not is_nil(@organization.username)} class="mt-6">
        <.section_title>{gettext("Address")}</.section_title>
        <p class="mt-2 font-mono text-sm text-slate-800 dark:text-slate-200" id="fediverse-handle">
          @{@organization.username}@{VutuvWeb.Endpoint.host()}
        </p>

        <p class="mt-4 text-sm text-slate-700 dark:text-slate-300">
          <%= if @federated? do %>
            {gettext("This page is visible on other networks. %{count} accounts there follow it.",
              count: delimited_count(@remote_followers)
            )}
          <% else %>
            {gettext("This page is not visible on other networks. Nothing of it leaves vutuv.")}
          <% end %>
        </p>

        <%!-- The thing people are surprised by afterwards, so it is said before
        rather than after: switching off stops new posts leaving, but a copy
        another server already keeps can only be ASKED to go. --%>
        <p class="mt-3 text-sm text-slate-600 dark:text-slate-400">
          {gettext("Switching this off stops new posts from leaving. Copies another server already holds can only be asked to delete them, never made to.")}
        </p>

        <.button
          id="toggle-fediverse"
          phx-click="toggle"
          variant={if @federated?, do: "secondary", else: "primary"}
          data-confirm={
            if @federated?,
              do: nil,
              else:
                gettext(
                  "From now on, posts of this page also go to other networks. Continue?"
                )
          }
          class="mt-4"
        >
          {if @federated?, do: gettext("Switch it off"), else: gettext("Switch it on")}
        </.button>
      </.card>

      <p
        :if={@ever_federated? and not @federated?}
        class="mt-4 text-sm text-slate-600 dark:text-slate-400"
      >
        {gettext("This page was visible on other networks before. Servers that still hold copies keep them until they act on a deletion request.")}
      </p>
    </div>
    """
  end
end
