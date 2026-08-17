defmodule VutuvWeb.OrganizationLive.Apps do
  @moduledoc """
  The owner's switch for reaching a page from a Mastodon-compatible app
  (`/organizations/:slug/apps`) — the page twin of a member's
  `/settings/apps`.

  Its own tab rather than a card on the Fediverse one, and the distinction is
  the point: federating publishes the page to servers we do not run and cannot
  be fully taken back, while this only decides whether the Editorial team may
  reach the page from a phone app. A team that wants one does not necessarily
  want the other.

  **Owner-only**, like federating and unlike the feed and the follows list the
  Redaktion may read: this is an administrative question about the page rather
  than part of speaking for it. Re-asked on every write, because a socket
  outlives the grant that opened it.

  Ships **off**. So the page has to say what turning it on is for and, above
  all, which address to type into the app — an adapter nobody can find an
  address for is not a feature. The host comes from the endpoint, so an
  installation that is not vutuv.de shows its own.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.OrganizationComponents, only: [manage_header: 1]

  alias Vutuv.MastodonApi
  alias Vutuv.Organizations
  alias VutuvWeb.Live.InitAssigns

  @impl true
  def mount(_params, session, socket) do
    socket = InitAssigns.assign_embedded(socket, session)
    organization = Organizations.get_organization!(session["organization_id"])

    {:ok,
     socket
     |> assign(:page_title, gettext("Apps – %{name}", name: organization.name))
     |> assign(:enabled?, MastodonApi.enabled?())
     |> assign(:organization, organization)}
  end

  @impl true
  def handle_event("toggle", _params, socket) do
    organization = socket.assigns.organization

    if Organizations.owner?(organization, socket.assigns.current_user) do
      {:ok, organization} =
        Organizations.set_mastodon_clients(organization, !organization.mastodon_clients?)

      {:noreply, assign(socket, :organization, organization)}
    else
      {:noreply,
       put_flash(socket, :error, gettext("You are not allowed to change this organization."))}
    end
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl py-6">
      <.manage_header organization={@organization} active={:apps} viewer={@current_user} />

      <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">{gettext("Apps")}</h1>
      <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
        {gettext(
          "Apps built for Mastodon can write in this page's name, read its feed and notify its team."
        )}
      </p>

      <.card :if={!@enabled?} class="mt-6">
        <p class="text-sm text-slate-700 dark:text-slate-300">
          {gettext("This vutuv serves no app interface, so nothing here has any effect.")}
        </p>
      </.card>

      <.card class="mt-6" id="mastodon-client-access">
        <.section_title>{gettext("Mastodon-compatible apps")}</.section_title>
        <p class="mt-2 text-sm text-slate-700 dark:text-slate-300">
          {gettext(
            "The page's Editorial team can use this organization as a separate identity in a compatible phone app, with the same rights they already have here. Those rights are checked again on every request."
          )}
        </p>
        <p class="mt-2 text-sm text-slate-700 dark:text-slate-300">
          {gettext(
            "Whoever posted stays recorded, so the team can always tell who wrote what — and an app signed in as this page cannot block anybody, because blocking is between two people."
          )}
        </p>
        <.button class="mt-3" phx-click="toggle" variant="secondary">
          {if @organization.mastodon_clients?,
            do: gettext("Turn app access off"),
            else: gettext("Turn app access on")}
        </.button>
      </.card>

      <%!-- The address, verbatim and selectable, because typing the wrong one is
      the single way this fails for a team that did everything right. Only once
      the switch is on and the page has a handle: without a handle there is no
      account address to name, and the Fediverse tab is where one is claimed. --%>
      <.card :if={@organization.mastodon_clients?} class="mt-6" id="mastodon-address">
        <.section_title>{gettext("The address to type into the app")}</.section_title>
        <p class="mt-2 select-all font-mono text-base text-slate-900 dark:text-white">
          {MastodonApi.local_domain()}
        </p>
        <p :if={@organization.username} class="mt-2 text-sm text-slate-600 dark:text-slate-400">
          {gettext("Sign in with your own account, then pick %{name} on the approval screen.",
            name: @organization.name
          )}
        </p>
        <p :if={is_nil(@organization.username)} class="mt-2 text-sm text-slate-600 dark:text-slate-400">
          {gettext(
            "Sign in with your own account, then pick this page on the approval screen. A short @name is not needed for that, only for being followed from another server."
          )}
        </p>
        <p class="mt-3">
          <.link
            navigate={~p"/system/mastodon"}
            class="text-sm font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
          >
            {gettext("How to set up an app")} ›
          </.link>
        </p>
      </.card>
    </div>
    """
  end
end
