defmodule VutuvWeb.CompanyLive.New do
  @moduledoc """
  The claim wizard (`/companies/new`, issue #929): name + website + full postal
  address, and the domain-proof method. Submitting creates a `pending` company
  and sends the owner to its page, where the domain-verification panel finishes
  the claim. Embedded via `live_render` from `VutuvWeb.CompanyController`, which
  gates it on a logged-in, email-confirmed member.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.CompanyComponents

  alias Vutuv.Companies
  alias Vutuv.Countries
  alias VutuvWeb.Live.InitAssigns

  @impl true
  def mount(_params, session, socket) do
    current_user = InitAssigns.load_user(session["user_id"])
    VutuvWeb.LiveLocale.put_locale(current_user, session)
    locale = session["locale"] || "en"

    socket =
      socket
      |> assign(:current_user, current_user)
      |> assign(:current_user_id, current_user && current_user.id)
      |> assign(:locale, locale)
      |> assign(:shell_path, session["request_path"])
      |> assign(:page_title, gettext("Claim a company"))
      |> assign(:method, "dns")
      |> assign(:countries, Countries.select_options(locale))
      |> assign_form(Companies.change_new_company())

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"company" => params}, socket) do
    changeset = %{Companies.change_new_company(params) | action: :validate}
    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("set_method", %{"method" => method}, socket)
      when method in ~w(dns well_known) do
    {:noreply, assign(socket, :method, method)}
  end

  def handle_event("save", %{"company" => params}, socket) do
    case Companies.create_pending_company(
           socket.assigns.current_user,
           params,
           socket.assigns.method
         ) do
      {:ok, %{company: company}} ->
        {:noreply, push_navigate(socket, to: ~p"/companies/#{company.slug}")}

      {:error, :domain_taken} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("That domain already belongs to another company page.")
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
    |> assign(:form, to_form(changeset, as: :company))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl py-6">
      <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">{gettext("Claim a company")}</h1>
      <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
        {gettext("A company page can only exist once you prove control of its web domain.")}
      </p>

      <.form for={@form} id="company-form" phx-change="validate" phx-submit="save" class="mt-6 space-y-5">
        <.form_error :if={@changeset} changeset={@changeset} />

        <.text_field form={@form} field={:name} label={gettext("Company name")} />
        <.text_field
          form={@form}
          field={:website_url}
          label={gettext("Website")}
          type="url"
          placeholder="https://example.com"
        />

        <fieldset class="grid gap-4 sm:grid-cols-2">
          <.text_field form={@form} field={:street_address} label={gettext("Street address")} />
          <.text_field form={@form} field={:zip_code} label={gettext("ZIP / postal code")} />
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
            navigate={~p"/companies"}
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
