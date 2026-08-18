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

  **It also lists the tokens issued for the page, and that is the half that was
  missing.** A member turns the page's app access into a credential of their
  own accord; until now only that member could see or withdraw it, so an owner
  could not tell who was reaching the page from an app and had no way to stop
  one. The list is filtered by the issuing member and paged, because on a page
  with a large Editorial team the rows look alike and "who issued this" is the
  only question that narrows them.

  **Turning the switch off withdraws them all**, after saying how many. Leaving
  them alive would make the switch a lie: they stop working while it is off
  (`Access.authorize_token/2` re-checks the flag per request) and come back the
  moment somebody turns it on again, which is not what "off" means to whoever
  pressed it.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.OrganizationComponents, only: [manage_header: 1]

  alias Vutuv.ApiAuth
  alias Vutuv.ApiAuth.UserAgent
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
     |> assign(:organization, organization)
     |> assign(:filter, "")
     |> load_tokens(1)}
  end

  @impl true
  def handle_event("toggle", _params, socket) do
    organization = socket.assigns.organization

    if Organizations.owner?(organization, socket.assigns.current_user) do
      turning_off? = organization.mastodon_clients?

      {:ok, organization} =
        Organizations.set_mastodon_clients(organization, !organization.mastodon_clients?)

      # Every live token goes with the switch. The confirmation the owner
      # answered before this event named the count, so nothing is destroyed
      # without them having been told how much.
      revoked = if turning_off?, do: ApiAuth.revoke_organization_tokens!(organization), else: 0

      socket =
        socket
        |> assign(:organization, organization)
        |> load_tokens(1)
        |> maybe_report_revoked(revoked)

      {:noreply, socket}
    else
      {:noreply,
       put_flash(socket, :error, gettext("You are not allowed to change this organization."))}
    end
  end

  def handle_event("filter", %{"query" => query}, socket) do
    {:noreply, socket |> assign(:filter, query) |> load_tokens(1)}
  end

  def handle_event("page", %{"page" => page}, socket) do
    {:noreply, load_tokens(socket, String.to_integer(page))}
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    organization = socket.assigns.organization

    # Re-asked here, not trusted from mount: a socket outlives the grant that
    # opened it, so the role is checked on the write and not only on the read.
    if Organizations.owner?(organization, socket.assigns.current_user) do
      case ApiAuth.revoke_organization_token(organization, id) do
        {:ok, _token} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("The app can no longer act for this page."))
           |> load_tokens(socket.assigns.tokens.page)}

        {:error, :not_found} ->
          {:noreply, load_tokens(socket, socket.assigns.tokens.page)}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("You are not allowed to change this organization."))}
    end
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  # Two counts, because they answer two questions. `@tokens.total` is how many
  # rows the filter found, which is what the list says about itself; the switch
  # withdraws **every** token, so its confirmation has to name the unfiltered
  # count. Sharing one number let a filter narrowed to a single colleague
  # promise that "the one app token" was going, with thirty behind it.
  defp load_tokens(socket, page) do
    organization = socket.assigns.organization

    socket
    |> assign(:tokens, ApiAuth.organization_tokens(organization, socket.assigns.filter, page))
    |> assign(:token_count, ApiAuth.count_organization_tokens(organization))
  end

  defp maybe_report_revoked(socket, 0), do: socket

  defp maybe_report_revoked(socket, count) do
    put_flash(
      socket,
      :info,
      ngettext(
        "App access is off. One app token was withdrawn.",
        "App access is off. %{count} app tokens were withdrawn.",
        count
      )
    )
  end

  @doc """
  The device a token was minted from, as a row shows it.

  The label and not the raw string: a member is answering "which of my devices
  is this", and a client string that names nothing recognisable is better said
  as "unknown device" than guessed at. See `Vutuv.ApiAuth.UserAgent`.
  """
  def device_label(token) do
    UserAgent.label(token.user_agent) || gettext("unknown device")
  end

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
        <%!-- Turning it off withdraws every token, so the confirmation names
        how many rather than asking about an abstraction. Turning it on takes
        nothing away and asks nothing. --%>
        <.button
          class="mt-3"
          phx-click="toggle"
          variant="secondary"
          data-confirm={
            @organization.mastodon_clients? && @token_count > 0 &&
              ngettext(
                "Turn app access off? The one app token issued for this page is withdrawn and stops working immediately.",
                "Turn app access off? All %{count} app tokens issued for this page are withdrawn and stop working immediately.",
                @token_count
              )
          }
        >
          {if @organization.mastodon_clients?,
            do: gettext("Turn app access off"),
            else: gettext("Turn app access on")}
        </.button>
      </.card>

      <%!-- Who is reaching this page from an app. A member issues such a token
      themselves, and until now only they could see or withdraw it — so an owner
      could not tell who had one, let alone stop one. --%>
      <.card :if={@organization.mastodon_clients?} class="mt-6" id="organization-app-tokens">
        <.section_title>{gettext("App access in use")}</.section_title>
        <p class="mt-2 text-sm text-slate-700 dark:text-slate-300">
          {gettext(
            "Each row is one app signed in as this page, issued by the team member named on it. Withdrawing one stops that app immediately; the member keeps their own account."
          )}
        </p>

        <form phx-change="filter" phx-submit="filter" class="mt-4">
          <label for="token-filter" class="sr-only">
            {gettext("Filter by the member who issued the token")}
          </label>
          <input
            type="search"
            id="token-filter"
            name="query"
            value={@filter}
            phx-debounce="300"
            placeholder={gettext("Filter by member (name or @handle)")}
            class={input_class()}
          />
        </form>

        <p :if={@tokens.entries == []} class="card__empty">
          {if @filter in [nil, ""],
            do: gettext("No app is signed in as this page."),
            else: gettext("No token matches that member.")}
        </p>

        <div :if={@tokens.entries != []} class="mt-4">
          <p class="text-sm text-slate-600 dark:text-slate-400">
            <%!-- The exact figure, not a compacted one: an owner deciding
            whether to turn the switch off is counting credentials. `ngettext/3`
            binds %{count} to the raw integer and a binding cannot override it,
            so the formatted number rides its own placeholder. --%>
            {ngettext("One app token", "%{formatted} app tokens", @tokens.total,
              formatted: delimited_count(@tokens.total)
            )}
          </p>

          <ul class="mt-2 divide-y divide-slate-100 dark:divide-slate-800">
            <li
              :for={token <- @tokens.entries}
              class="flex flex-wrap items-start gap-3 py-4 first:pt-0 last:pb-0"
              data-app-token={token.id}
            >
              <div class="min-w-0 flex-1">
                <p class="font-medium text-slate-800 dark:text-slate-100">
                  {(token.app && token.app.name) || gettext("Personal access token")}
                </p>
                <p class="mt-0.5 text-sm text-slate-600 dark:text-slate-400">
                  {gettext("Issued by")}
                  <.link
                    navigate={~p"/#{token.user.username}"}
                    class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
                  >
                    {VutuvWeb.UserHelpers.full_name(token.user)}
                  </.link>
                  · <.local_time at={token.inserted_at} id={"token-at-#{token.id}"} style={:datetime} />
                  · {device_label(token)}
                </p>
              </div>
              <.button
                variant="danger"
                phx-click="revoke"
                phx-value-id={token.id}
                data-confirm={
                  gettext("Withdraw this app's access to the page? It stops working immediately.")
                }
              >
                {gettext("Withdraw")}
              </.button>
            </li>
          </ul>

          <.admin_pager
            :if={@tokens.pages > 1}
            page={@tokens.page}
            pages={@tokens.pages}
            prev_id="tokens-prev"
            next_id="tokens-next"
          />
        </div>
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
