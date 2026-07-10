defmodule VutuvWeb.CompanyLive.Edit do
  @moduledoc """
  The owner edit form for a company page (`/companies/:slug/edit`, issue #929):
  the wizard fields minus verification, plus the Markdown description, a logo
  upload, and the machine-visibility toggles (`seo?`/`geo?`). Embedded via
  `live_render` from `VutuvWeb.CompanyController`, which gates it on a member who
  may manage the company.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.CompanyComponents
  import VutuvWeb.ErrorHelpers

  alias Vutuv.Companies
  alias Vutuv.Countries
  alias VutuvWeb.Live.InitAssigns

  @impl true
  def mount(_params, session, socket) do
    current_user = InitAssigns.load_user(session["user_id"])
    VutuvWeb.LiveLocale.put_locale(current_user, session)
    locale = session["locale"] || "en"
    company = Companies.get_company!(session["company_id"])

    socket =
      socket
      |> assign(:current_user, current_user)
      |> assign(:current_user_id, current_user && current_user.id)
      |> assign(:locale, locale)
      |> assign(:shell_path, session["request_path"])
      |> assign(:company, company)
      |> assign(:page_title, gettext("Edit %{name}", name: company.name))
      |> assign(:countries, Countries.select_options(locale))
      |> allow_upload(:logo,
        accept: Vutuv.CompanyImageStore.extension_whitelist(),
        max_entries: 1,
        max_file_size: 4_000_000
      )
      |> assign_form(Companies.change_company(company))

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"company" => params}, socket) do
    changeset = %{Companies.change_company(socket.assigns.company, params) | action: :validate}
    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("remove_logo", _params, socket) do
    {:ok, company} = Companies.remove_logo(socket.assigns.company)
    {:noreply, assign(socket, :company, company)}
  end

  def handle_event("save", %{"company" => params}, socket) do
    case Companies.update_company(socket.assigns.company, params) do
      {:ok, company} ->
        company = consume_logo(socket, company)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Your company page was updated."))
         |> push_navigate(to: ~p"/companies/#{company.slug}")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, %{changeset | action: :update})}
    end
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  defp consume_logo(socket, company) do
    results =
      consume_uploaded_entries(socket, :logo, fn %{path: path}, entry ->
        {:ok, Companies.store_logo(company, socket.assigns.current_user, path, entry.client_name)}
      end)

    case results do
      [{:ok, updated} | _] -> updated
      _ -> company
    end
  end

  defp assign_form(socket, changeset) do
    socket
    |> assign(:changeset, changeset)
    |> assign(:form, to_form(changeset, as: :company))
  end

  defp checked?(value), do: value in [true, "true"]

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl py-6">
      <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">
        {gettext("Edit %{name}", name: @company.name)}
      </h1>

      <.form for={@form} id="company-form" phx-change="validate" phx-submit="save" class="mt-6 space-y-5">
        <.form_error :if={@changeset} changeset={@changeset} />

        <div>
          <span class="block text-sm font-semibold text-slate-700 dark:text-slate-200">{gettext("Logo")}</span>
          <div class="mt-2 flex items-center gap-4">
            <.company_logo company={@company} class="h-16 w-16 shrink-0" />
            <div class="space-y-2">
              <.live_file_input upload={@uploads.logo} class="text-sm" />
              <button
                :if={@company.logo}
                type="button"
                phx-click="remove_logo"
                class="block text-xs font-semibold text-red-600 hover:text-red-700"
              >
                {gettext("Remove logo")}
              </button>
              <p :for={err <- upload_errors(@uploads.logo)} class="text-xs text-red-600">
                {upload_error_to_string(err)}
              </p>
            </div>
          </div>
        </div>

        <.text_field form={@form} field={:name} label={gettext("Company name")} />

        <div>
          <label class="block text-sm font-semibold text-slate-700 dark:text-slate-200">
            {gettext("Description")}
          </label>
          <p class="text-xs text-slate-600 dark:text-slate-400">{gettext("Markdown is supported")}</p>
          <.markdown_editor
            id="company-description"
            name="company[description]"
            value={@form[:description].value || ""}
            label={gettext("Description")}
            class="mt-1"
          />
          {error_tag(@form, :description)}
        </div>

        <.text_field form={@form} field={:website_url} label={gettext("Website")} type="url" />

        <fieldset class="grid gap-4 sm:grid-cols-2">
          <.text_field form={@form} field={:street_address} label={gettext("Street address")} />
          <.text_field form={@form} field={:zip_code} label={gettext("ZIP / postal code")} />
          <.text_field form={@form} field={:city} label={gettext("City")} />
          <.text_field form={@form} field={:state} label={gettext("State / region (optional)")} />
        </fieldset>

        <.country_select form={@form} countries={@countries} label={gettext("Country")} />

        <fieldset class="space-y-3 rounded-lg bg-slate-50 p-4 dark:bg-slate-800/60">
          <legend class="text-sm font-semibold text-slate-700 dark:text-slate-200">
            {gettext("Visibility")}
          </legend>
          <label class="flex items-start gap-3 text-sm">
            <input type="hidden" name="company[seo?]" value="false" />
            <input
              type="checkbox"
              name="company[seo?]"
              value="true"
              checked={checked?(@form[:seo?].value)}
              class={checkbox_class()}
            />
            <span>
              <span class="font-medium text-slate-800 dark:text-slate-200">{gettext("Search engines")}</span>
              <span class="block text-xs text-slate-600 dark:text-slate-400">
                {gettext("Let search engines index this page and include it in the sitemap.")}
              </span>
            </span>
          </label>
          <label class="flex items-start gap-3 text-sm">
            <input type="hidden" name="company[geo?]" value="false" />
            <input
              type="checkbox"
              name="company[geo?]"
              value="true"
              checked={checked?(@form[:geo?].value)}
              class={checkbox_class()}
            />
            <span>
              <span class="font-medium text-slate-800 dark:text-slate-200">{gettext("AI agents")}</span>
              <span class="block text-xs text-slate-600 dark:text-slate-400">
                {gettext("Offer the machine-readable formats (.md/.txt/.json/.xml) and list them for AI agents.")}
              </span>
            </span>
          </label>
        </fieldset>

        <div class="flex items-center gap-3 pt-2">
          <button
            type="submit"
            class="rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white hover:bg-brand-700"
          >
            {gettext("Save")}
          </button>
          <.link
            navigate={~p"/companies/#{@company.slug}"}
            class="text-sm font-semibold text-slate-600 hover:text-slate-800 dark:text-slate-400 dark:hover:text-slate-200"
          >
            {gettext("Cancel")}
          </.link>
        </div>
      </.form>
    </div>
    """
  end

  defp upload_error_to_string(:too_large), do: gettext("The file is too large.")
  defp upload_error_to_string(:too_many_files), do: gettext("You can only upload one logo.")
  defp upload_error_to_string(:not_accepted), do: gettext("That file type is not allowed.")
  defp upload_error_to_string(_), do: gettext("The upload failed.")
end
