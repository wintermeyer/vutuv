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
      |> assign(:owner?, Companies.owner?(company, current_user))
      |> assign(:page_title, gettext("Edit %{name}", name: company.name))
      |> assign(:countries, Countries.select_options(locale))
      |> assign(:aliases, Companies.list_aliases(company))
      |> assign(:alias_name, "")
      |> assign(:alias_kind, "alias")
      |> assign(:handle_value, company.username || "")
      |> assign(:handle_error, nil)
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

  def handle_event("update_alias", params, socket) do
    {:noreply,
     socket
     |> assign(:alias_name, params["name"] || socket.assigns.alias_name)
     |> assign(:alias_kind, params["kind"] || socket.assigns.alias_kind)}
  end

  def handle_event("add_alias", %{"name" => name} = params, socket) do
    kind = params["kind"] || "alias"

    case String.trim(name) do
      "" ->
        {:noreply, socket}

      trimmed ->
        case Companies.add_alias(socket.assigns.company, trimmed, kind) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:alias_name, "")
             |> assign(:aliases, Companies.list_aliases(socket.assigns.company))
             |> put_flash(:info, gettext("Alias added."))}

          {:error, _changeset} ->
            {:noreply,
             put_flash(socket, :error, gettext("That name is already listed for this company."))}
        end
    end
  end

  def handle_event("remove_alias", %{"id" => id}, socket) do
    case Companies.get_alias(socket.assigns.company, id) do
      nil ->
        {:noreply, socket}

      company_name ->
        {:ok, _} = Companies.remove_alias(company_name)

        {:noreply,
         socket
         |> assign(:aliases, Companies.list_aliases(socket.assigns.company))
         |> put_flash(:info, gettext("Alias removed."))}
    end
  end

  def handle_event("claim_handle", %{"username" => username}, socket) do
    case Companies.claim_handle(socket.assigns.company, %{"username" => username}) do
      {:ok, company} ->
        {:noreply,
         socket
         |> assign(:company, company)
         |> assign(:handle_value, company.username)
         |> assign(:handle_error, nil)
         |> put_flash(:info, gettext("Your company handle is set."))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:handle_value, username)
         |> assign(:handle_error, handle_error_message(changeset))}
    end
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  # First field error on the handle changeset, translated for display.
  defp handle_error_message(changeset) do
    case changeset.errors[:username] do
      {msg, opts} -> translate_error({msg, opts})
      _ -> gettext("That handle is not available.")
    end
  end

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
      <.manage_header company={@company} active={:edit} owner?={@owner?} />

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
          <.text_field form={@form} field={:street_address} label={gettext("Street address (optional)")} />
          <.text_field form={@form} field={:zip_code} label={gettext("ZIP / postal code (optional)")} />
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

      <.card class="mt-8">
        <.section_title>{gettext("Also known as")}</.section_title>
        <p class="mt-1 text-xs text-slate-600 dark:text-slate-400">
          {gettext("Alternative names, brands or abbreviations this company is findable under. A rename keeps the old name here automatically.")}
        </p>

        <ul :if={@aliases != []} class="mt-3 divide-y divide-slate-100 dark:divide-slate-800">
          <li :for={company_name <- @aliases} id={"alias-#{company_name.id}"} class="flex items-center gap-3 py-2">
            <span class="min-w-0 flex-1">
              <span class="truncate font-medium text-slate-900 dark:text-slate-100">{company_name.name}</span>
              <span class="ml-2 rounded-full bg-slate-100 px-2 py-0.5 text-xs font-semibold text-slate-600 dark:bg-slate-800 dark:text-slate-300">
                {alias_kind_label(company_name.kind)}
              </span>
            </span>
            <button
              type="button"
              phx-click="remove_alias"
              phx-value-id={company_name.id}
              data-confirm={gettext("Remove this name?")}
              class="shrink-0 text-sm font-semibold text-red-600 hover:text-red-700"
            >
              {gettext("Remove")}
            </button>
          </li>
        </ul>

        <.form for={%{}} id="add-alias-form" phx-submit="add_alias" phx-change="update_alias" class="mt-4 flex flex-wrap items-center gap-3">
          <input
            type="text"
            name="name"
            value={@alias_name}
            autocomplete="off"
            placeholder={gettext("Alternative name")}
            class={[input_class(), "flex-1"]}
          />
          <select name="kind" class={[input_class(), "w-auto"]}>
            <option value="alias" selected={@alias_kind == "alias"}>{gettext("Alias")}</option>
            <option value="brand" selected={@alias_kind == "brand"}>{gettext("Brand")}</option>
            <option value="abbreviation" selected={@alias_kind == "abbreviation"}>{gettext("Abbreviation")}</option>
          </select>
          <button
            type="submit"
            class="rounded-lg bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
          >
            {gettext("Add")}
          </button>
        </.form>
      </.card>

      <.card :if={@owner?} class="mt-8">
        <.section_title>{gettext("Root handle")}</.section_title>
        <p class="mt-1 text-xs text-slate-600 dark:text-slate-400">
          {gettext(
            "Claim a short @handle so this company has its own root URL, like a member profile. Letters, numbers and underscores, 3 to 15 characters."
          )}
        </p>

        <p :if={@company.username} class="mt-3 text-sm text-slate-700 dark:text-slate-300">
          {gettext("Reachable at")}
          <a
            href={"/" <> @company.username}
            class="font-semibold text-brand-600 hover:text-brand-700"
          >
            {VutuvWeb.Endpoint.host()}/{@company.username}
          </a>
        </p>

        <.form
          for={%{}}
          id="claim-handle-form"
          phx-submit="claim_handle"
          class="mt-4 flex flex-wrap items-start gap-3"
        >
          <div class="flex-1">
            <input
              type="text"
              name="username"
              value={@handle_value}
              autocomplete="off"
              placeholder={gettext("your_company")}
              aria-invalid={@handle_error && "true"}
              class={[input_class(@handle_error not in [nil, ""]), "w-full"]}
            />
            <p :if={@handle_error} class="mt-1 text-xs text-red-600">{@handle_error}</p>
          </div>
          <button
            type="submit"
            class="rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white hover:bg-brand-700"
          >
            {if @company.username, do: gettext("Change"), else: gettext("Claim")}
          </button>
        </.form>
      </.card>
    </div>
    """
  end

  defp upload_error_to_string(:too_large), do: gettext("The file is too large.")
  defp upload_error_to_string(:too_many_files), do: gettext("You can only upload one logo.")
  defp upload_error_to_string(:not_accepted), do: gettext("That file type is not allowed.")
  defp upload_error_to_string(_), do: gettext("The upload failed.")
end
