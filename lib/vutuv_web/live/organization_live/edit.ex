defmodule VutuvWeb.OrganizationLive.Edit do
  @moduledoc """
  The owner edit form for an organization page (`/organizations/:slug/edit`, issue #929):
  the wizard fields minus verification, plus the Markdown description, a logo
  upload, and the machine-visibility toggles (`seo?`/`geo?`). Embedded via
  `live_render` from `VutuvWeb.OrganizationController`, which gates it on a member who
  may manage the organization.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.OrganizationComponents
  import VutuvWeb.ErrorHelpers

  alias Vutuv.Countries
  alias Vutuv.Organizations
  alias VutuvWeb.Live.InitAssigns

  @impl true
  def mount(_params, session, socket) do
    current_user = InitAssigns.load_user(session["user_id"])
    VutuvWeb.LiveLocale.put_locale(current_user, session)
    locale = session["locale"] || "en"
    organization = Organizations.get_organization!(session["organization_id"])

    socket =
      socket
      |> assign(:current_user, current_user)
      |> assign(:current_user_id, current_user && current_user.id)
      |> assign(:locale, locale)
      |> assign(:shell_path, session["request_path"])
      |> assign(:organization, organization)
      |> assign(:owner?, Organizations.owner?(organization, current_user))
      |> assign(:page_title, gettext("Edit %{name}", name: organization.name))
      |> assign(:countries, Countries.select_options(locale))
      |> assign(:aliases, Organizations.list_aliases(organization))
      |> assign(:alias_name, "")
      |> assign(:alias_kind, "alias")
      |> assign(:handle_value, organization.username || "")
      |> assign(:handle_error, nil)
      |> allow_upload(:logo,
        accept: Vutuv.OrganizationImageStore.extension_whitelist(),
        max_entries: 1,
        max_file_size: 4_000_000
      )
      |> assign_form(Organizations.change_organization(organization))

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"organization" => params}, socket) do
    changeset = %{
      Organizations.change_organization(socket.assigns.organization, params)
      | action: :validate
    }

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("remove_logo", _params, socket) do
    {:ok, organization} = Organizations.remove_logo(socket.assigns.organization)
    {:noreply, assign(socket, :organization, organization)}
  end

  def handle_event("save", %{"organization" => params}, socket) do
    case Organizations.update_organization(socket.assigns.organization, params) do
      {:ok, organization} ->
        organization = consume_logo(socket, organization)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Your organization page was updated."))
         |> push_navigate(to: ~p"/organizations/#{organization.slug}")}

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
        case Organizations.add_alias(socket.assigns.organization, trimmed, kind) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:alias_name, "")
             |> assign(:aliases, Organizations.list_aliases(socket.assigns.organization))
             |> put_flash(:info, gettext("Alias added."))}

          {:error, _changeset} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("That name is already listed for this organization.")
             )}
        end
    end
  end

  def handle_event("remove_alias", %{"id" => id}, socket) do
    case Organizations.get_alias(socket.assigns.organization, id) do
      nil ->
        {:noreply, socket}

      organization_name ->
        {:ok, _} = Organizations.remove_alias(organization_name)

        {:noreply,
         socket
         |> assign(:aliases, Organizations.list_aliases(socket.assigns.organization))
         |> put_flash(:info, gettext("Alias removed."))}
    end
  end

  def handle_event("claim_handle", %{"username" => username}, socket) do
    case Organizations.claim_handle(socket.assigns.organization, %{"username" => username}) do
      {:ok, organization} ->
        {:noreply,
         socket
         |> assign(:organization, organization)
         |> assign(:handle_value, organization.username)
         |> assign(:handle_error, nil)
         |> put_flash(:info, gettext("Your organization handle is set."))}

      {:error, :not_verified} ->
        {:noreply,
         socket
         |> assign(:handle_value, username)
         |> assign(
           :handle_error,
           gettext("Only a verified organization page can claim a handle.")
         )}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:handle_value, username)
         |> assign(:handle_error, handle_error_message(changeset))}
    end
  end

  def handle_event("delete_organization", _params, socket) do
    organization = socket.assigns.organization

    if socket.assigns.owner? and Organizations.deletable?(organization) do
      {:ok, _} = Organizations.delete_organization(organization)

      {:noreply,
       socket
       |> put_flash(:info, gettext("The organization page was deleted."))
       |> push_navigate(to: ~p"/organizations")}
    else
      # The button is owner-gated, but re-check here: an organization admin (not an
      # owner) can reach the edit page, and deletion is owner-only.
      {:noreply,
       put_flash(socket, :error, gettext("You are not allowed to delete this organization."))}
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

  defp consume_logo(socket, organization) do
    results =
      consume_uploaded_entries(socket, :logo, fn %{path: path}, entry ->
        {:ok,
         Organizations.store_logo(
           organization,
           socket.assigns.current_user,
           path,
           entry.client_name
         )}
      end)

    case results do
      [{:ok, updated} | _] -> updated
      _ -> organization
    end
  end

  defp assign_form(socket, changeset) do
    socket
    |> assign(:changeset, changeset)
    |> assign(:form, to_form(changeset, as: :organization))
  end

  defp checked?(value), do: value in [true, "true"]

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl py-6">
      <.manage_header organization={@organization} active={:edit} owner?={@owner?} manage?={true} />

      <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">
        {gettext("Edit %{name}", name: @organization.name)}
      </h1>

      <.form for={@form} id="organization-form" phx-change="validate" phx-submit="save" class="mt-6 space-y-5">
        <.form_error :if={@changeset} changeset={@changeset} />

        <div>
          <span class="block text-sm font-semibold text-slate-700 dark:text-slate-200">{gettext("Logo")}</span>
          <div class="mt-2 flex items-center gap-4">
            <.organization_logo organization={@organization} class="h-16 w-16 shrink-0" />
            <div class="space-y-2">
              <.live_file_input upload={@uploads.logo} class="text-sm" />
              <button
                :if={@organization.logo}
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

        <.text_field form={@form} field={:name} label={gettext("Organization name")} />
        <.kind_select form={@form} label={gettext("Kind of organization")} />

        <div>
          <label class="block text-sm font-semibold text-slate-700 dark:text-slate-200">
            {gettext("Description")}
          </label>
          <p class="text-xs text-slate-600 dark:text-slate-400">{gettext("Markdown is supported")}</p>
          <.markdown_editor
            id="organization-description"
            name="organization[description]"
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
            <input type="hidden" name="organization[seo?]" value="false" />
            <input
              type="checkbox"
              name="organization[seo?]"
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
            <input type="hidden" name="organization[geo?]" value="false" />
            <input
              type="checkbox"
              name="organization[geo?]"
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
            navigate={~p"/organizations/#{@organization.slug}"}
            class="text-sm font-semibold text-slate-600 hover:text-slate-800 dark:text-slate-400 dark:hover:text-slate-200"
          >
            {gettext("Cancel")}
          </.link>
        </div>
      </.form>

      <.card class="mt-8">
        <.section_title>{gettext("Also known as")}</.section_title>
        <p class="mt-1 text-xs text-slate-600 dark:text-slate-400">
          {gettext("Alternative names, brands or abbreviations this organization is findable under. A rename keeps the old name here automatically.")}
        </p>

        <ul :if={@aliases != []} class="mt-3 divide-y divide-slate-100 dark:divide-slate-800">
          <li :for={organization_name <- @aliases} id={"alias-#{organization_name.id}"} class="flex items-center gap-3 py-2">
            <span class="min-w-0 flex-1">
              <span class="truncate font-medium text-slate-900 dark:text-slate-100">{organization_name.name}</span>
              <span class="ml-2 rounded-full bg-slate-100 px-2 py-0.5 text-xs font-semibold text-slate-600 dark:bg-slate-800 dark:text-slate-300">
                {alias_kind_label(organization_name.kind)}
              </span>
            </span>
            <button
              type="button"
              phx-click="remove_alias"
              phx-value-id={organization_name.id}
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

      <.card :if={@owner? and @organization.status == "active"} class="mt-8">
        <.section_title>{gettext("Root handle")}</.section_title>
        <p class="mt-1 text-xs text-slate-600 dark:text-slate-400">
          {gettext(
            "Claim a short @handle so this organization has its own root URL, like a member profile. Letters, numbers and underscores, %{min} to %{max} characters.",
            min: Vutuv.Handles.min_length(),
            max: Vutuv.Handles.max_length()
          )}
        </p>

        <p :if={@organization.username} class="mt-3 text-sm text-slate-700 dark:text-slate-300">
          {gettext("Reachable at")}
          <a
            href={"/" <> @organization.username}
            class="font-semibold text-brand-600 hover:text-brand-700"
          >
            {VutuvWeb.Endpoint.host()}/{@organization.username}
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
              placeholder={gettext("your_organization")}
              aria-invalid={@handle_error && "true"}
              class={[input_class(@handle_error not in [nil, ""]), "w-full"]}
            />
            <p :if={@handle_error} class="mt-1 text-xs text-red-600">{@handle_error}</p>
          </div>
          <button
            type="submit"
            class="rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white hover:bg-brand-700"
          >
            {if @organization.username, do: gettext("Change"), else: gettext("Claim")}
          </button>
        </.form>
      </.card>

      <.card :if={@owner?} class="mt-8 ring-red-200 dark:ring-red-900/50">
        <.section_title>{gettext("Danger zone")}</.section_title>
        <p class="mt-1 text-xs text-slate-600 dark:text-slate-400">
          {gettext(
            "Deleting this organization page is permanent. Its verified domains and its @handle are freed and can be claimed again."
          )}
        </p>
        <button
          id="delete-organization"
          type="button"
          phx-click="delete_organization"
          data-confirm={
            gettext("Really delete %{name}? This cannot be undone.", name: @organization.name)
          }
          class="mt-3 rounded-lg bg-red-600 px-4 py-2 text-sm font-semibold text-white hover:bg-red-700"
        >
          {gettext("Delete this organization")}
        </button>
      </.card>
    </div>
    """
  end

  defp upload_error_to_string(:too_large), do: gettext("The file is too large.")
  defp upload_error_to_string(:too_many_files), do: gettext("You can only upload one logo.")
  defp upload_error_to_string(:not_accepted), do: gettext("That file type is not allowed.")
  defp upload_error_to_string(_), do: gettext("The upload failed.")
end
