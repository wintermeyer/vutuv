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
      <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
        {gettext("Let people on Mastodon and other networks follow this page and receive its posts.")}
      </p>

      <.card :if={!@enabled?} class="mt-6">
        <p class="text-sm text-slate-700 dark:text-slate-300">
          {gettext("This installation has federation switched off, so nothing here has any effect.")}
        </p>
      </.card>

      <.card :if={@enabled? and is_nil(@organization.username)} class="mt-6" id="needs-handle">
        <.section_title>{gettext("A handle is needed first")}</.section_title>
        <p class="mt-2 text-sm text-slate-700 dark:text-slate-300">
          {gettext("Out there this page is addressed by its handle, the way a member is. Claim one on the page settings, then come back.")}
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
            {gettext("This page is being federated. %{count} accounts on other networks follow it.",
              count: delimited_count(@remote_followers)
            )}
          <% else %>
            {gettext("This page is not being federated. Nothing of it is visible on other networks.")}
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
                gettext("Posts of this page will be sent to other servers from now on. Continue?")
          }
          class="mt-4"
        >
          {if @federated?, do: gettext("Stop federating"), else: gettext("Start federating")}
        </.button>
      </.card>

      <p
        :if={@ever_federated? and not @federated?}
        class="mt-4 text-sm text-slate-600 dark:text-slate-400"
      >
        {gettext("This page federated before. Servers that still hold copies keep them until they act on a deletion request.")}
      </p>
    </div>
    """
  end
end
