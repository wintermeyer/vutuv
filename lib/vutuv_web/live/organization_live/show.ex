defmodule VutuvWeb.OrganizationLive.Show do
  @moduledoc """
  A verified organization page (`/organizations/:slug`, issue #929). Embedded via
  `live_render` from `VutuvWeb.OrganizationController` (off-router, like the
  profile); the agent-format siblings stay controller-owned.

  For a public viewer it shows the read-only page (logo, name, verified-domain
  badge, description, address, website) plus the like / bookmark controls
  (reload-free `phx-click`, the like count live over PubSub). The owner of a
  still-`pending` page sees the domain-verification panel instead (resume the
  claim), and a frozen page keeps only the owner + admins, behind the moderation
  banner.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.OrganizationComponents
  import VutuvWeb.JobComponents, only: [job_card: 1]

  alias Vutuv.Countries
  alias Vutuv.Jobs
  alias Vutuv.Organizations
  alias VutuvWeb.JsonLd
  alias VutuvWeb.Live.InitAssigns
  alias VutuvWeb.UserHelpers

  @impl true
  def mount(_params, session, socket) do
    current_user = InitAssigns.load_user(session["user_id"])
    VutuvWeb.LiveLocale.put_locale(current_user, session)

    organization = Organizations.get_organization!(session["organization_id"])
    if connected?(socket), do: Organizations.subscribe(organization.id)

    socket =
      socket
      |> assign(:current_user, current_user)
      |> assign(:current_user_id, current_user && current_user.id)
      |> assign(:locale, session["locale"])
      |> assign(:shell_path, session["request_path"])
      |> assign_organization(organization, current_user)
      |> assign_people(organization)
      |> assign_org_jobs(organization)

    {:ok, socket}
  end

  # The organization page's "Offene Stellen" section (#933): the organization's
  # own live public postings, newest first, paginated (its own "Load more" event
  # so it never collides with the People list's). Static cards — the board is
  # where the like / bookmark actions live (they would clash with the page's own
  # organization-level toggle_like/toggle_bookmark here).
  defp assign_org_jobs(socket, organization) do
    total = Jobs.organization_postings_count(organization)

    page =
      if total > 0,
        do: Jobs.list_organization_postings(organization),
        else: %{entries: [], more?: false, next_offset: 0}

    socket
    |> assign(:org_jobs, page.entries)
    |> assign(:org_jobs_total, total)
    |> assign(:org_jobs_more?, page.more?)
    |> assign(:org_jobs_offset, page.next_offset)
  end

  # The organization page's "People" section (issue #931): members whose linked work
  # experience is at this organization, current members first. Loaded once at mount
  # (state-transition events keep their own paging); "Load more" appends the next
  # page. The list honors the member-directory privacy gate in the context.
  defp assign_people(socket, organization) do
    total = Organizations.organization_people_count(organization)

    page =
      if total > 0,
        do: Organizations.organization_people_page(organization),
        else: %{entries: [], more?: false, next_offset: 0}

    socket
    |> assign(:people, page.entries)
    |> assign(:people_total, total)
    |> assign(:people_more?, page.more?)
    |> assign(:people_offset, page.next_offset)
  end

  defp assign_organization(socket, organization, viewer) do
    # One query for every domain, partitioned in memory (an organization has few).
    domains = Organizations.list_domains(organization)
    primary = Enum.find(domains, & &1.primary?)

    socket
    |> assign(:organization, organization)
    |> assign(:page_title, organization.name)
    |> assign(:verified_domains, Enum.filter(domains, & &1.verified_at))
    |> assign(:primary_domain, primary)
    |> assign(:aliases, Organizations.list_aliases(organization))
    |> assign(:country_name, Countries.name(organization.country))
    |> assign(:can_manage?, Organizations.can_manage?(organization, viewer))
    |> assign(:can_edit?, Organizations.can_edit_page?(organization, viewer))
    |> assign(:owner?, Organizations.owner?(organization, viewer))
    |> assign(:pending?, organization.status == "pending")
    |> assign(:frozen?, not is_nil(organization.frozen_at))
    |> assign(:engagement, Organizations.organization_engagement(organization, viewer))
    |> assign(:dns_value, primary && Organizations.dns_txt_value(primary))
    |> assign(:dns_challenge_name, primary && Organizations.dns_challenge_name(primary))
    |> assign(:well_known_url, primary && Organizations.well_known_url(primary))
    |> assign(:well_known_content, primary && Organizations.well_known_content(primary))
    |> assign(:verification_enabled?, Organizations.verification_enabled?())
  end

  @impl true
  def handle_event("load-more", _params, socket) do
    page =
      Organizations.organization_people_page(socket.assigns.organization,
        offset: socket.assigns.people_offset
      )

    {:noreply,
     socket
     |> assign(:people, socket.assigns.people ++ page.entries)
     |> assign(:people_more?, page.more?)
     |> assign(:people_offset, page.next_offset)}
  end

  def handle_event("load-more-jobs", _params, socket) do
    page =
      Jobs.list_organization_postings(socket.assigns.organization,
        offset: socket.assigns.org_jobs_offset
      )

    {:noreply,
     socket
     |> assign(:org_jobs, socket.assigns.org_jobs ++ page.entries)
     |> assign(:org_jobs_more?, page.more?)
     |> assign(:org_jobs_offset, page.next_offset)}
  end

  def handle_event("toggle_like", _params, socket), do: {:noreply, toggle(socket, :like)}

  def handle_event("toggle_bookmark", _params, socket), do: {:noreply, toggle(socket, :bookmark)}

  def handle_event("set_method", %{"method" => method}, socket)
      when method in ~w(dns well_known) do
    if socket.assigns.can_edit? and socket.assigns.pending? do
      {:ok, _domain} = Organizations.set_domain_method(socket.assigns.primary_domain, method)

      {:noreply,
       assign_organization(socket, socket.assigns.organization, socket.assigns.current_user)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("verify", _params, socket) do
    if socket.assigns.can_edit? and socket.assigns.pending? do
      organization = socket.assigns.organization
      domain = socket.assigns.primary_domain

      case Organizations.verify_domain(organization, domain) do
        {:ok, organization} ->
          {:noreply,
           socket
           |> assign_organization(organization, socket.assigns.current_user)
           |> put_flash(:info, gettext("Your organization page is verified and now live."))}

        {:error, _reason} ->
          {:noreply,
           put_flash(socket, :error, verify_error_message(socket.assigns.verification_enabled?))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:organization_counters, %{likes: likes}}, socket) do
    {:noreply, assign(socket, :engagement, %{socket.assigns.engagement | likes: likes})}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # `primary_domain` is a %OrganizationDomain{} struct here (the assign holds the row
  # for the verify panel); set_method/verify need the struct, so re-fetch it.
  defp toggle(socket, kind) do
    case socket.assigns.current_user do
      nil ->
        push_navigate(socket, to: ~p"/login")

      user ->
        organization = socket.assigns.organization
        apply_engagement(kind, user, organization, socket.assigns.engagement)
        assign(socket, :engagement, Organizations.organization_engagement(organization, user))
    end
  end

  defp apply_engagement(:like, user, organization, %{liked?: true}),
    do: Organizations.unlike_organization(user, organization)

  defp apply_engagement(:like, user, organization, _),
    do: Organizations.like_organization(user, organization)

  defp apply_engagement(:bookmark, user, organization, %{bookmarked?: true}),
    do: Organizations.unbookmark_organization(user, organization)

  defp apply_engagement(:bookmark, user, organization, _),
    do: Organizations.bookmark_organization(user, organization)

  defp verify_error_message(true),
    do:
      gettext(
        "We could not find the record or file yet. It can take a while to propagate. Please try again."
      )

  defp verify_error_message(false),
    do: gettext("Domain verification is disabled on this installation.")

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6 py-6">
      <.frozen_banner :if={@can_manage? and @frozen?} class="rounded-2xl px-4 py-3 text-sm">
        {gettext("This organization page was reported and is hidden while it is reviewed. Only you and the moderators can see it.")}
      </.frozen_banner>

      <%= if @can_edit? and @pending? do %>
        {verify_panel(assigns)}
      <% else %>
        {public_page(assigns)}
      <% end %>
    </div>
    """
  end

  defp public_page(assigns) do
    ~H"""
    <div>
      <JsonLd.script
        :if={Organizations.indexable?(@organization)}
        data={JsonLd.organization_page(@organization, @verified_domains)}
      />

      <div class="flex flex-col gap-6 md:grid md:grid-cols-3">
        <div class="min-w-0 md:col-span-2 md:space-y-6">
          <.card>
            <div class="flex items-start gap-4">
              <.organization_logo organization={@organization} class="h-20 w-20 shrink-0" />
              <div class="min-w-0 flex-1">
                <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">{@organization.name}</h1>
                <div class="mt-2 flex flex-wrap items-center gap-2">
                  <.kind_badge kind={@organization.kind} />
                  <.verified_badge :if={@primary_domain} domain={@primary_domain.domain} />
                </div>
                <.organization_location organization={@organization} class="mt-2 text-sm text-slate-600 dark:text-slate-400" />
                <a
                  :if={@organization.website_url}
                  href={@organization.website_url}
                  rel="nofollow noopener"
                  target="_blank"
                  class="mt-2 inline-block text-sm font-semibold text-brand-600 hover:text-brand-700"
                >
                  {display_url(@organization.website_url)}
                </a>
              </div>
            </div>

            <div class="mt-6 flex flex-wrap items-center gap-4 border-t border-slate-100 pt-4 dark:border-slate-800">
              <button
                type="button"
                phx-click="toggle_like"
                aria-pressed={@engagement.liked?}
                class={["flex items-center gap-1.5 text-sm font-medium", @engagement.liked? && "text-accent"]}
              >
                <.icon_heart filled?={@engagement.liked?} class="h-5 w-5" />
                <span class="tabular-nums">{compact_count(@engagement.likes)}</span>
                <span class="sr-only">{gettext("Like")}</span>
              </button>

              <button
                type="button"
                phx-click="toggle_bookmark"
                aria-pressed={@engagement.bookmarked?}
                class={[
                  "flex items-center gap-1.5 text-sm font-medium",
                  @engagement.bookmarked? && "text-brand-600 dark:text-brand-300"
                ]}
              >
                <.icon_bookmark filled?={@engagement.bookmarked?} class="h-5 w-5" />
                <span class="sr-only">{gettext("Bookmark")}</span>
              </button>

              <div class="ml-auto flex flex-wrap items-center gap-4 text-sm">
                <.link
                  :if={@can_edit?}
                  navigate={~p"/organizations/#{@organization.slug}/edit"}
                  class="font-semibold text-brand-600 hover:text-brand-700"
                >
                  {gettext("Edit")}
                </.link>
                <.link
                  :if={@owner?}
                  navigate={~p"/organizations/#{@organization.slug}/roles"}
                  class="font-semibold text-brand-600 hover:text-brand-700"
                >
                  {gettext("Team")}
                </.link>
                <.link
                  :if={@owner?}
                  navigate={~p"/organizations/#{@organization.slug}/domains"}
                  class="font-semibold text-brand-600 hover:text-brand-700"
                >
                  {gettext("Domains")}
                </.link>
                <.link
                  :if={@current_user && !@can_manage?}
                  href={~p"/reports/new?#{[type: "organization", id: @organization.id, return_to: "/organizations/#{@organization.slug}"]}"}
                  class="text-slate-600 hover:text-slate-800 dark:text-slate-400 dark:hover:text-slate-200"
                >
                  {gettext("Report")}
                </.link>
              </div>
            </div>
          </.card>

          <.card :if={present?(@organization.description)}>
            <.section_title>{gettext("About")}</.section_title>
            <.markdown_prose text={@organization.description} class="mt-3 text-slate-800 dark:text-slate-200" />
          </.card>

          <%!-- People: members who list this organization as an employer (issue #931).
          Current members lead; a "Former" tag marks past ones. Plain profile
          links make each profile crawlable from the organization page. --%>
          <.card :if={@people_total > 0}>
            <div class="flex items-center justify-between">
              <.section_title>{gettext("People")}</.section_title>
              <span class="text-sm text-slate-600 dark:text-slate-400">{compact_count(@people_total)}</span>
            </div>
            <ul id="organization-people" class="mt-4 space-y-3">
              <li :for={person <- @people} class="flex items-center gap-3">
                <.avatar user={person.user} size="sm" shape="circle" />
                <div class="min-w-0">
                  <a
                    href={"/" <> person.user.username}
                    class="font-semibold text-slate-900 hover:text-brand-700 dark:text-slate-100 dark:hover:text-brand-400"
                  >
                    {UserHelpers.full_name(person.user)}
                  </a>
                  <p class="truncate text-sm text-slate-600 dark:text-slate-400">
                    {person.title}<span :if={not person.current?} class="text-slate-500 dark:text-slate-500">
                      · {gettext("Former")}</span>
                  </p>
                </div>
              </li>
            </ul>
            <.load_more :if={@people_more?} class="mt-4" />
          </.card>

          <%!-- Open positions (#933): this organization's live public postings.
          Plain profile-style cards linking each detail page, so every posting is
          crawlable from the organization page; the board is where the filters and
          the like / bookmark actions live. --%>
          <section :if={@org_jobs_total > 0} class="space-y-4">
            <div class="flex items-center justify-between">
              <.section_title>{gettext("Open positions")}</.section_title>
              <span class="text-sm text-slate-600 dark:text-slate-400">{compact_count(@org_jobs_total)}</span>
            </div>
            <div id="organization-jobs" class="grid gap-4 sm:grid-cols-2">
              <.job_card :for={posting <- @org_jobs} posting={posting} />
            </div>
            <div :if={@org_jobs_more?} class="text-center">
              <button
                type="button"
                id="load-more-jobs"
                phx-click="load-more-jobs"
                class="rounded-lg bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
              >
                {gettext("More jobs")}
              </button>
            </div>
          </section>
        </div>

        <aside class="space-y-6">
          <.card>
            <.section_title>{gettext("Address")}</.section_title>
            <address class="mt-3 space-y-0.5 text-sm not-italic text-slate-700 dark:text-slate-300">
              <div :if={present?(@organization.street_address)}>{@organization.street_address}</div>
              <div>{[@organization.zip_code, @organization.city] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")}</div>
              <div :if={present?(@organization.state)}>{@organization.state}</div>
              <div>{@country_name}</div>
            </address>
          </.card>

          <.card :if={@aliases != []}>
            <.section_title>{gettext("Also known as")}</.section_title>
            <ul class="mt-3 flex flex-wrap gap-2">
              <li
                :for={organization_name <- @aliases}
                class="rounded-lg bg-slate-100 px-2.5 py-1 text-sm font-medium text-slate-700 dark:bg-slate-800 dark:text-slate-200"
              >
                {organization_name.name}
              </li>
            </ul>
          </.card>

          <.card :if={length(@verified_domains) > 1}>
            <.section_title>{gettext("Verified domains")}</.section_title>
            <ul class="mt-3 space-y-1 text-sm text-slate-700 dark:text-slate-300">
              <li :for={domain <- @verified_domains}>{domain.domain}</li>
            </ul>
          </.card>

          <.other_formats_card
            base_path={"/organizations/" <> @organization.slug}
            locale={@locale}
            machine_formats={@organization.geo?}
          />
        </aside>
      </div>
    </div>
    """
  end

  defp verify_panel(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl">
      <.card>
        <h1 class="text-xl font-bold text-slate-900 dark:text-slate-100">
          {gettext("Verify %{name}", name: @organization.name)}
        </h1>
        <p class="mt-2 text-sm text-slate-600 dark:text-slate-400">
          {gettext("Prove you control %{domain} to publish this page.", domain: @primary_domain.domain)}
        </p>

        <%!-- Reassure the member who cannot touch DNS themselves: they can hand
        the record below to whoever runs their website and finish here later. --%>
        <p
          :if={@verification_enabled?}
          class="mt-4 rounded-lg bg-brand-50 p-4 text-sm text-slate-700 ring-1 ring-brand-100 dark:bg-brand-900/30 dark:text-slate-300 dark:ring-brand-900/50"
        >
          {gettext("These steps are technical. If you don't manage %{domain} yourself, copy the record or file shown below and send it to your IT team or whoever runs your website. Once they have added it, come back here and press Verify now.", domain: @primary_domain.domain)}
        </p>

        <%= if @verification_enabled? do %>
          <fieldset class="mt-6">
            <legend class="text-sm font-semibold text-slate-700 dark:text-slate-200">
              {gettext("Verification method")}
            </legend>
            <div class="mt-2 flex flex-col gap-2">
              <label class="flex items-center gap-2 text-sm">
                <input
                  type="radio"
                  name="method"
                  value="dns"
                  checked={@primary_domain.method == "dns"}
                  phx-click="set_method"
                  phx-value-method="dns"
                  class={checkbox_class()}
                /> {gettext("DNS TXT record")}
              </label>
              <label class="flex items-center gap-2 text-sm">
                <input
                  type="radio"
                  name="method"
                  value="well_known"
                  checked={@primary_domain.method == "well_known"}
                  phx-click="set_method"
                  phx-value-method="well_known"
                  class={checkbox_class()}
                /> {gettext("Website file")}
              </label>
            </div>
          </fieldset>

          <div class="mt-4 rounded-lg bg-slate-50 p-4 text-sm dark:bg-slate-800/60">
            <%= if @primary_domain.method == "dns" do %>
              <p class="text-slate-700 dark:text-slate-300">
                {gettext("In your DNS settings, create a TXT record on the name %{domain} with this value:",
                  domain: @primary_domain.domain
                )}
              </p>
              <code
                phx-no-curly-interpolation
                class="mt-2 block overflow-x-auto rounded bg-white px-3 py-2 font-mono text-xs text-slate-900 ring-1 ring-slate-200 dark:bg-slate-900 dark:text-slate-100 dark:ring-slate-700"
              ><%= @dns_value %></code>
              <p class="mt-2 text-xs text-slate-600 dark:text-slate-400">
                {gettext("If %{domain} is a CNAME / alias (a TXT record cannot share a name with a CNAME), put the record on %{name} instead, with the same value.",
                  domain: @primary_domain.domain,
                  name: @dns_challenge_name
                )}
              </p>
            <% else %>
              <p class="text-slate-700 dark:text-slate-300">
                {gettext("Serve this file at:")}
              </p>
              <code
                phx-no-curly-interpolation
                class="mt-2 block overflow-x-auto rounded bg-white px-3 py-2 font-mono text-xs text-slate-900 ring-1 ring-slate-200 dark:bg-slate-900 dark:text-slate-100 dark:ring-slate-700"
              ><%= @well_known_url %></code>
              <p class="mt-3 text-slate-700 dark:text-slate-300">{gettext("with this exact content:")}</p>
              <code
                phx-no-curly-interpolation
                class="mt-2 block overflow-x-auto rounded bg-white px-3 py-2 font-mono text-xs text-slate-900 ring-1 ring-slate-200 dark:bg-slate-900 dark:text-slate-100 dark:ring-slate-700"
              ><%= @well_known_content %></code>
            <% end %>
          </div>

          <button
            type="button"
            phx-click="verify"
            id="verify-domain"
            class="mt-6 rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white hover:bg-brand-700"
          >
            {gettext("Verify now")}
          </button>
        <% else %>
          <p class="mt-6 rounded-lg bg-amber-50 px-4 py-3 text-sm text-amber-800 dark:bg-amber-900/30 dark:text-amber-200">
            {gettext("Domain verification is disabled on this installation.")}
          </p>
        <% end %>
      </.card>
    </div>
    """
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp display_url(url),
    do: url |> String.replace(~r{^https?://}, "") |> String.trim_trailing("/")
end
