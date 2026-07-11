defmodule VutuvWeb.CompanyLive.Show do
  @moduledoc """
  A verified company page (`/companies/:slug`, issue #929). Embedded via
  `live_render` from `VutuvWeb.CompanyController` (off-router, like the
  profile); the agent-format siblings stay controller-owned.

  For a public viewer it shows the read-only page (logo, name, verified-domain
  badge, description, address, website) plus the like / bookmark controls
  (reload-free `phx-click`, the like count live over PubSub). The owner of a
  still-`pending` page sees the domain-verification panel instead (resume the
  claim), and a frozen page keeps only the owner + admins, behind the moderation
  banner.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.CompanyComponents

  alias Vutuv.Companies
  alias Vutuv.Countries
  alias VutuvWeb.JsonLd
  alias VutuvWeb.Live.InitAssigns

  @impl true
  def mount(_params, session, socket) do
    current_user = InitAssigns.load_user(session["user_id"])
    VutuvWeb.LiveLocale.put_locale(current_user, session)

    company = Companies.get_company!(session["company_id"])
    if connected?(socket), do: Companies.subscribe(company.id)

    socket =
      socket
      |> assign(:current_user, current_user)
      |> assign(:current_user_id, current_user && current_user.id)
      |> assign(:locale, session["locale"])
      |> assign(:shell_path, session["request_path"])
      |> assign_company(company, current_user)

    {:ok, socket}
  end

  defp assign_company(socket, company, viewer) do
    # One query for every domain, partitioned in memory (a company has few).
    domains = Companies.list_domains(company)
    primary = Enum.find(domains, & &1.primary?)

    socket
    |> assign(:company, company)
    |> assign(:page_title, company.name)
    |> assign(:verified_domains, Enum.filter(domains, & &1.verified_at))
    |> assign(:primary_domain, primary)
    |> assign(:aliases, Companies.list_aliases(company))
    |> assign(:country_name, Countries.name(company.country))
    |> assign(:can_manage?, Companies.can_manage?(company, viewer))
    |> assign(:can_edit?, Companies.can_edit_page?(company, viewer))
    |> assign(:owner?, Companies.owner?(company, viewer))
    |> assign(:pending?, company.status == "pending")
    |> assign(:frozen?, not is_nil(company.frozen_at))
    |> assign(:engagement, Companies.company_engagement(company, viewer))
    |> assign(:dns_value, primary && Companies.dns_txt_value(primary))
    |> assign(:well_known_url, primary && Companies.well_known_url(primary))
    |> assign(:well_known_content, primary && Companies.well_known_content(primary))
    |> assign(:verification_enabled?, Companies.verification_enabled?())
  end

  @impl true
  def handle_event("toggle_like", _params, socket), do: {:noreply, toggle(socket, :like)}

  def handle_event("toggle_bookmark", _params, socket), do: {:noreply, toggle(socket, :bookmark)}

  def handle_event("set_method", %{"method" => method}, socket)
      when method in ~w(dns well_known) do
    if socket.assigns.can_edit? and socket.assigns.pending? do
      {:ok, _domain} = Companies.set_domain_method(socket.assigns.primary_domain, method)
      {:noreply, assign_company(socket, socket.assigns.company, socket.assigns.current_user)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("verify", _params, socket) do
    if socket.assigns.can_edit? and socket.assigns.pending? do
      company = socket.assigns.company
      domain = socket.assigns.primary_domain

      case Companies.verify_domain(company, domain) do
        {:ok, company} ->
          {:noreply,
           socket
           |> assign_company(company, socket.assigns.current_user)
           |> put_flash(:info, gettext("Your company page is verified and now live."))}

        {:error, _reason} ->
          {:noreply,
           put_flash(socket, :error, verify_error_message(socket.assigns.verification_enabled?))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:company_counters, %{likes: likes}}, socket) do
    {:noreply, assign(socket, :engagement, %{socket.assigns.engagement | likes: likes})}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # `primary_domain` is a %CompanyDomain{} struct here (the assign holds the row
  # for the verify panel); set_method/verify need the struct, so re-fetch it.
  defp toggle(socket, kind) do
    case socket.assigns.current_user do
      nil ->
        push_navigate(socket, to: ~p"/login")

      user ->
        company = socket.assigns.company
        apply_engagement(kind, user, company, socket.assigns.engagement)
        assign(socket, :engagement, Companies.company_engagement(company, user))
    end
  end

  defp apply_engagement(:like, user, company, %{liked?: true}),
    do: Companies.unlike_company(user, company)

  defp apply_engagement(:like, user, company, _), do: Companies.like_company(user, company)

  defp apply_engagement(:bookmark, user, company, %{bookmarked?: true}),
    do: Companies.unbookmark_company(user, company)

  defp apply_engagement(:bookmark, user, company, _),
    do: Companies.bookmark_company(user, company)

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
        {gettext("This company page was reported and is hidden while it is reviewed. Only you and the moderators can see it.")}
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
        :if={Companies.indexable?(@company)}
        data={JsonLd.organization_page(@company, @verified_domains)}
      />

      <div class="flex flex-col gap-6 md:grid md:grid-cols-3">
        <div class="min-w-0 md:col-span-2 md:space-y-6">
          <.card>
            <div class="flex items-start gap-4">
              <.company_logo company={@company} class="h-20 w-20 shrink-0" />
              <div class="min-w-0 flex-1">
                <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">{@company.name}</h1>
                <div class="mt-2 flex flex-wrap items-center gap-2">
                  <.verified_badge :if={@primary_domain} domain={@primary_domain.domain} />
                </div>
                <.company_location company={@company} class="mt-2 text-sm text-slate-600 dark:text-slate-400" />
                <a
                  :if={@company.website_url}
                  href={@company.website_url}
                  rel="nofollow noopener"
                  target="_blank"
                  class="mt-2 inline-block text-sm font-semibold text-brand-600 hover:text-brand-700"
                >
                  {display_url(@company.website_url)}
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
                  navigate={~p"/companies/#{@company.slug}/edit"}
                  class="font-semibold text-brand-600 hover:text-brand-700"
                >
                  {gettext("Edit")}
                </.link>
                <.link
                  :if={@owner?}
                  navigate={~p"/companies/#{@company.slug}/roles"}
                  class="font-semibold text-brand-600 hover:text-brand-700"
                >
                  {gettext("Team")}
                </.link>
                <.link
                  :if={@owner?}
                  navigate={~p"/companies/#{@company.slug}/domains"}
                  class="font-semibold text-brand-600 hover:text-brand-700"
                >
                  {gettext("Domains")}
                </.link>
                <.link
                  :if={@current_user && !@can_manage?}
                  href={~p"/reports/new?#{[type: "company", id: @company.id, return_to: "/companies/#{@company.slug}"]}"}
                  class="text-slate-600 hover:text-slate-800 dark:text-slate-400 dark:hover:text-slate-200"
                >
                  {gettext("Report")}
                </.link>
              </div>
            </div>
          </.card>

          <.card :if={present?(@company.description)}>
            <.section_title>{gettext("About")}</.section_title>
            <.markdown_prose text={@company.description} class="mt-3 text-slate-800 dark:text-slate-200" />
          </.card>
        </div>

        <aside class="space-y-6">
          <.card>
            <.section_title>{gettext("Address")}</.section_title>
            <address class="mt-3 space-y-0.5 text-sm not-italic text-slate-700 dark:text-slate-300">
              <div :if={present?(@company.street_address)}>{@company.street_address}</div>
              <div>{[@company.zip_code, @company.city] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")}</div>
              <div :if={present?(@company.state)}>{@company.state}</div>
              <div>{@country_name}</div>
            </address>
          </.card>

          <.card :if={@aliases != []}>
            <.section_title>{gettext("Also known as")}</.section_title>
            <ul class="mt-3 flex flex-wrap gap-2">
              <li
                :for={company_name <- @aliases}
                class="rounded-lg bg-slate-100 px-2.5 py-1 text-sm font-medium text-slate-700 dark:bg-slate-800 dark:text-slate-200"
              >
                {company_name.name}
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
            base_path={"/companies/" <> @company.slug}
            locale={@locale}
            machine_formats={@company.geo?}
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
          {gettext("Verify %{name}", name: @company.name)}
        </h1>
        <p class="mt-2 text-sm text-slate-600 dark:text-slate-400">
          {gettext("Prove you control %{domain} to publish this page.", domain: @primary_domain.domain)}
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
                {gettext("Add this TXT record to %{domain}:", domain: @primary_domain.domain)}
              </p>
              <code
                phx-no-curly-interpolation
                class="mt-2 block overflow-x-auto rounded bg-white px-3 py-2 font-mono text-xs text-slate-900 ring-1 ring-slate-200 dark:bg-slate-900 dark:text-slate-100 dark:ring-slate-700"
              ><%= @dns_value %></code>
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
