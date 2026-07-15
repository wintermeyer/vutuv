defmodule VutuvWeb.OrganizationLive.New do
  @moduledoc """
  The claim wizard (`/organizations/new`, issue #929): name + website + full postal
  address, and the domain-proof method. Submitting creates a `pending` organization
  and sends the owner to its page, where the domain-verification panel finishes
  the claim. Embedded via `live_render` from `VutuvWeb.OrganizationController`, which
  gates it on a logged-in, email-confirmed member.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.OrganizationComponents

  alias Vutuv.Countries
  alias Vutuv.Organizations
  alias VutuvWeb.Live.InitAssigns

  @impl true
  def mount(_params, session, socket) do
    locale = session["locale"] || "en"

    socket =
      socket
      |> InitAssigns.assign_embedded(session)
      |> assign(:locale, locale)
      |> assign(:page_title, gettext("Add your organization"))
      |> assign(:method, "dns")
      |> assign(:countries, Countries.select_options(locale))
      |> assign_form(Organizations.change_new_organization())

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"organization" => params}, socket) do
    changeset = %{Organizations.change_new_organization(params) | action: :validate}
    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("set_method", %{"method" => method}, socket)
      when method in ~w(dns well_known) do
    {:noreply, assign(socket, :method, method)}
  end

  def handle_event("save", %{"organization" => params}, socket) do
    case Organizations.create_pending_organization(
           socket.assigns.current_user,
           params,
           socket.assigns.method
         ) do
      {:ok, %{organization: organization}} ->
        {:noreply, push_navigate(socket, to: ~p"/organizations/#{organization.slug}")}

      {:error, :domain_taken} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("That domain already belongs to another organization page.")
         )}

      {:error, changeset} ->
        {:noreply, assign_form(socket, %{changeset | action: :insert})}
    end
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  defp assign_form(socket, changeset) do
    socket
    |> assign(:changeset, changeset)
    |> assign(:form, to_form(changeset, as: :organization))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl py-6">
      <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">{gettext("Add your organization")}</h1>
      <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
        {gettext("Create a verified page for your company, association, school or public authority.")}
      </p>

      <%!-- Non-technical members were lost by the bare "prove control of the
      domain" line: they did not know why verification exists or that it is a
      job for whoever runs their website. This box answers both before the form. --%>
      <div class="mt-4 space-y-4 rounded-2xl bg-brand-50 p-5 text-sm ring-1 ring-brand-100 dark:bg-brand-900/30 dark:ring-brand-900/50">
        <div>
          <h2 class="font-semibold text-slate-900 dark:text-slate-100">
            {gettext("Why we ask you to verify")}
          </h2>
          <p class="mt-1 text-slate-700 dark:text-slate-300">
            {gettext("So visitors can trust the page. We only publish it once you prove that you control the organization's web domain, so nobody can put up a page that pretends to be your organization.")}
          </p>
        </div>
        <div>
          <h2 class="font-semibold text-slate-900 dark:text-slate-100">
            {gettext("You might need help from your admin")}
          </h2>
          <p class="mt-1 text-slate-700 dark:text-slate-300">
            {gettext("The proof is a small technical change to your domain: a DNS entry or a file on your website. If you don't manage the website yourself, ask the person or team who does. That is usually your IT department or the company that runs your website. We show the exact instructions on the next step, so you can simply pass them on.")}
          </p>
        </div>
      </div>

      <.form for={@form} id="organization-form" phx-change="validate" phx-submit="save" class="mt-6 space-y-5">
        <.form_error :if={@changeset} changeset={@changeset} />

        <.text_field form={@form} field={:name} label={gettext("Organization name")} />
        <.kind_select form={@form} label={gettext("Kind of organization")} />
        <.text_field
          form={@form}
          field={:website_url}
          label={gettext("Website")}
          type="url"
          placeholder="https://example.com"
        />

        <fieldset class="grid gap-4 sm:grid-cols-2">
          <.text_field form={@form} field={:street_address} label={gettext("Street address (optional)")} />
          <.text_field form={@form} field={:zip_code} label={gettext("ZIP / postal code (optional)")} />
          <.text_field form={@form} field={:city} label={gettext("City")} />
          <.text_field form={@form} field={:state} label={gettext("State / region (optional)")} />
        </fieldset>

        <.country_select form={@form} countries={@countries} label={gettext("Country")} />

        <fieldset>
          <legend class="text-sm font-semibold text-slate-700 dark:text-slate-200">
            {gettext("Verification method")}
          </legend>
          <p class="mt-1 text-xs text-slate-600 dark:text-slate-400">
            {gettext("You will publish a record or file to prove control of the domain on the next step.")}
          </p>
          <div class="mt-2 flex flex-col gap-2">
            <label class="flex items-center gap-2 text-sm">
              <input
                type="radio"
                name="method"
                value="dns"
                checked={@method == "dns"}
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
                checked={@method == "well_known"}
                phx-click="set_method"
                phx-value-method="well_known"
                class={checkbox_class()}
              /> {gettext("Website file (.well-known)")}
            </label>
          </div>
        </fieldset>

        <div class="flex items-center gap-3 pt-2">
          <button
            type="submit"
            class="rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white hover:bg-brand-700"
          >
            {gettext("Continue to verification")}
          </button>
          <.link
            navigate={~p"/organizations"}
            class="text-sm font-semibold text-slate-600 hover:text-slate-800 dark:text-slate-400 dark:hover:text-slate-200"
          >
            {gettext("Cancel")}
          </.link>
        </div>
      </.form>
    </div>
    """
  end
end
