defmodule VutuvWeb.OrganizationLive.Domains do
  @moduledoc """
  The owner-only multi-domain management page (`/organizations/:slug/domains`, issue
  #930). List the verified domains with method + last-checked time, add a domain
  (re-running the #929 verification wizard for exactly that host), remove one,
  and pick the primary — the domain shown in the page's "Verifiziert über …"
  badge. Every active organization keeps ≥ 1 verified domain; removing the primary
  auto-promotes another. Embedded via `live_render` from the controller, gated
  on an owner.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.OrganizationComponents, only: [manage_header: 1]

  alias Vutuv.Organizations
  alias VutuvWeb.Live.InitAssigns

  @impl true
  def mount(_params, session, socket) do
    current_user = InitAssigns.load_user(session["user_id"])
    VutuvWeb.LiveLocale.put_locale(current_user, session)
    organization = Organizations.get_organization!(session["organization_id"])

    {:ok,
     socket
     |> assign(:current_user, current_user)
     |> assign(:current_user_id, current_user && current_user.id)
     |> assign(:locale, session["locale"])
     |> assign(:shell_path, session["request_path"])
     |> assign(:organization, organization)
     |> assign(:page_title, gettext("Domains – %{name}", name: organization.name))
     |> assign(:new_domain, "")
     |> assign(:new_method, "dns")
     |> assign(:verification_enabled?, Organizations.verification_enabled?())
     |> load_domains()}
  end

  defp load_domains(socket) do
    domains = Organizations.list_domains(socket.assigns.organization)

    socket
    |> assign(:domains, domains)
    |> assign(:verified_count, Enum.count(domains, & &1.verified_at))
  end

  @impl true
  def handle_event("update_new", params, socket) do
    {:noreply,
     socket
     |> assign(:new_domain, params["domain"] || socket.assigns.new_domain)
     |> assign(:new_method, params["method"] || socket.assigns.new_method)}
  end

  def handle_event("add_domain", %{"domain" => domain} = params, socket) do
    method = params["method"] || "dns"
    organization = socket.assigns.organization

    case Organizations.add_domain(organization, domain, method) do
      {:ok, _domain} ->
        {:noreply,
         socket
         |> assign(:new_domain, "")
         |> load_domains()
         |> put_flash(:info, gettext("Domain added. Publish the record or file, then verify it."))}

      {:error, :domain_taken} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("That domain already belongs to an organization page.")
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("That is not a valid domain."))}
    end
  end

  def handle_event("set_method", %{"id" => id, "method" => method}, socket)
      when method in ~w(dns well_known) do
    with domain when not is_nil(domain) <-
           Organizations.get_domain(socket.assigns.organization, id),
         true <- is_nil(domain.verified_at) do
      {:ok, _} = Organizations.set_domain_method(domain, method)
      {:noreply, load_domains(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("verify", %{"id" => id}, socket) do
    organization = socket.assigns.organization

    case Organizations.get_domain(organization, id) do
      nil ->
        {:noreply, socket}

      domain ->
        case Organizations.verify_domain(organization, domain) do
          {:ok, _organization} ->
            {:noreply, socket |> load_domains() |> put_flash(:info, gettext("Domain verified."))}

          {:error, _} ->
            {:noreply,
             put_flash(socket, :error, verify_error(socket.assigns.verification_enabled?))}
        end
    end
  end

  def handle_event("set_primary", %{"id" => id}, socket) do
    with domain when not is_nil(domain) <-
           Organizations.get_domain(socket.assigns.organization, id),
         {:ok, _} <- Organizations.set_primary_domain(socket.assigns.organization, domain) do
      {:noreply, socket |> load_domains() |> put_flash(:info, gettext("Primary domain updated."))}
    else
      {:error, :not_verified} ->
        {:noreply,
         put_flash(socket, :error, gettext("Only a verified domain can be the primary one."))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    case Organizations.get_domain(socket.assigns.organization, id) do
      nil ->
        {:noreply, socket}

      domain ->
        case Organizations.remove_domain(socket.assigns.organization, domain) do
          {:ok, _} ->
            {:noreply, socket |> load_domains() |> put_flash(:info, gettext("Domain removed."))}

          {:error, :last_domain} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext(
                 "An organization keeps at least one verified domain, so this one cannot be removed."
               )
             )}
        end
    end
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  defp verify_error(true),
    do:
      gettext(
        "We could not find the record or file yet. It can take a while to propagate. Please try again."
      )

  defp verify_error(false), do: gettext("Domain verification is disabled on this installation.")

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl py-6">
      <.manage_header organization={@organization} active={:domains} owner?={true} />

      <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">{gettext("Domains")}</h1>
      <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
        {gettext("An organization can prove several domains. The primary one shows in the “Verified via …” badge.")}
      </p>

      <div :if={!@verification_enabled?} class="mt-4 rounded-lg bg-amber-50 px-4 py-3 text-sm text-amber-800 dark:bg-amber-900/30 dark:text-amber-200">
        {gettext("Domain verification is disabled on this installation.")}
      </div>

      <ul class="mt-6 space-y-4">
        <li :for={domain <- @domains} id={"domain-#{domain.id}"} class="rounded-2xl bg-white p-5 shadow-sm ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800">
          <div class="flex flex-wrap items-center gap-2">
            <span class="font-mono text-sm font-semibold text-slate-900 dark:text-slate-100">{domain.domain}</span>
            <span :if={domain.primary?} class="rounded-full bg-brand-50 px-2 py-0.5 text-xs font-semibold text-brand-700 dark:bg-brand-900/40 dark:text-brand-100">
              {gettext("Primary")}
            </span>
            <span :if={domain.verified_at} class="rounded-full bg-emerald-50 px-2 py-0.5 text-xs font-semibold text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-200">
              {gettext("Verified")}
            </span>
            <span :if={!domain.verified_at} class="rounded-full bg-slate-100 px-2 py-0.5 text-xs font-semibold text-slate-600 dark:bg-slate-800 dark:text-slate-300">
              {gettext("Pending")}
            </span>
          </div>

          <p :if={domain.last_checked_at} class="mt-1 text-xs text-slate-600 dark:text-slate-400">
            {gettext("Method")}: {domain.method} &middot; {gettext("Last checked")}:
            <.local_time at={domain.last_checked_at} id={"domain-checked-#{domain.id}"} />
          </p>

          {verify_block(assigns, domain)}

          <div class="mt-4 flex flex-wrap items-center gap-4 border-t border-slate-100 pt-3 dark:border-slate-800">
            <button
              :if={domain.verified_at && !domain.primary?}
              type="button"
              phx-click="set_primary"
              phx-value-id={domain.id}
              class="text-sm font-semibold text-brand-600 hover:text-brand-700"
            >
              {gettext("Make primary")}
            </button>
            <button
              type="button"
              phx-click="remove"
              phx-value-id={domain.id}
              data-confirm={gettext("Remove this domain?")}
              class="ml-auto text-sm font-semibold text-red-600 hover:text-red-700"
            >
              {gettext("Remove")}
            </button>
          </div>
        </li>
      </ul>

      <.card :if={@verification_enabled?} class="mt-6">
        <.section_title>{gettext("Add a domain")}</.section_title>
        <.form for={%{}} id="add-domain-form" phx-submit="add_domain" phx-change="update_new" class="mt-3 space-y-3">
          <input
            type="text"
            name="domain"
            value={@new_domain}
            autocomplete="off"
            placeholder="example.com"
            class={input_class()}
          />
          <div class="flex flex-wrap items-center gap-3">
            <select name="method" class={[input_class(), "w-auto"]}>
              <option value="dns" selected={@new_method == "dns"}>{gettext("DNS TXT record")}</option>
              <option value="well_known" selected={@new_method == "well_known"}>{gettext("Website file")}</option>
            </select>
            <button
              type="submit"
              class="rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white hover:bg-brand-700"
            >
              {gettext("Add")}
            </button>
          </div>
        </.form>
      </.card>
    </div>
    """
  end

  # The verification instructions shown inline under a still-pending domain: the
  # method toggle, the record/file to publish, and the "Verify now" button.
  defp verify_block(assigns, domain) do
    assigns =
      assign(assigns, :domain, domain)
      |> assign(:dns_value, Organizations.dns_txt_value(domain))
      |> assign(:dns_challenge_name, Organizations.dns_challenge_name(domain))
      |> assign(:well_known_url, Organizations.well_known_url(domain))
      |> assign(:well_known_content, Organizations.well_known_content(domain))

    ~H"""
    <div :if={is_nil(@domain.verified_at) and @verification_enabled?} class="mt-3 rounded-lg bg-slate-50 p-4 text-sm dark:bg-slate-800/60">
      <div class="flex gap-4">
        <label class="flex items-center gap-1.5 text-xs font-medium">
          <input
            type="radio"
            checked={@domain.method == "dns"}
            phx-click="set_method"
            phx-value-id={@domain.id}
            phx-value-method="dns"
            class={checkbox_class()}
          /> {gettext("DNS TXT record")}
        </label>
        <label class="flex items-center gap-1.5 text-xs font-medium">
          <input
            type="radio"
            checked={@domain.method == "well_known"}
            phx-click="set_method"
            phx-value-id={@domain.id}
            phx-value-method="well_known"
            class={checkbox_class()}
          /> {gettext("Website file")}
        </label>
      </div>

      <%= if @domain.method == "dns" do %>
        <p class="mt-3 text-slate-700 dark:text-slate-300">{gettext("In your DNS settings, create a TXT record on the name %{domain} with this value:", domain: @domain.domain)}</p>
        <code phx-no-curly-interpolation class="mt-1 block overflow-x-auto rounded bg-white px-3 py-2 font-mono text-xs text-slate-900 ring-1 ring-slate-200 dark:bg-slate-900 dark:text-slate-100 dark:ring-slate-700"><%= @dns_value %></code>
        <p class="mt-2 text-xs text-slate-600 dark:text-slate-400">{gettext("If %{domain} is a CNAME / alias (a TXT record cannot share a name with a CNAME), put the record on %{name} instead, with the same value.", domain: @domain.domain, name: @dns_challenge_name)}</p>
      <% else %>
        <p class="mt-3 text-slate-700 dark:text-slate-300">{gettext("Serve this file at:")}</p>
        <code phx-no-curly-interpolation class="mt-1 block overflow-x-auto rounded bg-white px-3 py-2 font-mono text-xs text-slate-900 ring-1 ring-slate-200 dark:bg-slate-900 dark:text-slate-100 dark:ring-slate-700"><%= @well_known_url %></code>
        <p class="mt-2 text-slate-700 dark:text-slate-300">{gettext("with this exact content:")}</p>
        <code phx-no-curly-interpolation class="mt-1 block overflow-x-auto rounded bg-white px-3 py-2 font-mono text-xs text-slate-900 ring-1 ring-slate-200 dark:bg-slate-900 dark:text-slate-100 dark:ring-slate-700"><%= @well_known_content %></code>
      <% end %>

      <button
        type="button"
        phx-click="verify"
        phx-value-id={@domain.id}
        id={"verify-#{@domain.id}"}
        class="mt-3 rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white hover:bg-brand-700"
      >
        {gettext("Verify now")}
      </button>
    </div>
    """
  end
end
