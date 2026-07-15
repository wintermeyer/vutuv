defmodule VutuvWeb.OrganizationLive.Exclusions do
  @moduledoc """
  The organization standing-default job-exclusion editor
  (`/organizations/:slug/exclusions`, issue #939), editable by any role holder.
  A verified organization sets, once, the members, organizations and email
  domains it never wants to advertise vacancies to; every posting attributed to
  the organization inherits the list (the effective set is this default ∪ the
  posting's own list) and it takes effect immediately on all live postings.

  Embedded via `live_render` from the controller, gated on `can_manage?`. Drives
  the shared `VutuvWeb.JobExclusionComponents.exclusion_panel/1`.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.JobExclusionComponents
  import VutuvWeb.OrganizationComponents, only: [manage_header: 1]

  alias Vutuv.Jobs.Exclusions
  alias Vutuv.Organizations
  alias VutuvWeb.Live.InitAssigns

  @impl true
  def mount(_params, session, socket) do
    socket = InitAssigns.assign_embedded(socket, session)
    current_user = socket.assigns.current_user
    organization = Organizations.get_organization!(session["organization_id"])

    {:ok,
     socket
     |> assign(:organization, organization)
     |> assign(:owner?, Organizations.owner?(organization, current_user))
     |> assign(:page_title, gettext("Job exclusions – %{name}", name: organization.name))
     |> assign(:member_error, nil)
     |> assign(:org_error, nil)
     |> assign_member_form()
     |> assign_org_form()
     |> assign_domain_form()
     |> load_exclusions()}
  end

  @impl true
  def handle_event("add_member", %{"member" => %{"handle" => handle}}, socket) do
    case Exclusions.add_organization_member(socket.assigns.organization, handle) do
      {:ok, _} ->
        {:noreply,
         socket |> assign(:member_error, nil) |> assign_member_form() |> load_exclusions()}

      {:error, reason} ->
        {:noreply, assign(socket, :member_error, member_error_message(reason))}
    end
  end

  def handle_event("add_organization", %{"organization" => %{"handle" => handle}}, socket) do
    case Exclusions.add_organization_organization(socket.assigns.organization, handle) do
      {:ok, _} ->
        {:noreply, socket |> assign(:org_error, nil) |> assign_org_form() |> load_exclusions()}

      {:error, reason} ->
        {:noreply, assign(socket, :org_error, org_error_message(reason))}
    end
  end

  def handle_event("add_domain", %{"domain" => params}, socket) do
    case Exclusions.add_organization_domain(socket.assigns.organization, params) do
      {:ok, _} ->
        {:noreply, socket |> assign_domain_form() |> load_exclusions()}

      {:error, changeset} ->
        {:noreply, assign(socket, :domain_form, to_form(changeset, as: :domain))}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    :ok = Exclusions.remove_from_organization(socket.assigns.organization, id)
    {:noreply, load_exclusions(socket)}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_exclusions(socket),
    do: assign(socket, :exclusions, Exclusions.list_for_organization(socket.assigns.organization))

  defp assign_member_form(socket),
    do: assign(socket, :member_form, to_form(%{"handle" => ""}, as: :member))

  defp assign_org_form(socket),
    do: assign(socket, :org_form, to_form(%{"handle" => ""}, as: :organization))

  defp assign_domain_form(socket) do
    changeset = Exclusions.change_organization_domain(socket.assigns.organization)
    assign(socket, :domain_form, to_form(changeset, as: :domain))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl py-6">
      <.manage_header organization={@organization} active={:exclusions} owner?={@owner?} manage?={true} />

      <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">
        {gettext("Job exclusions")}
      </h1>
      <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
        {gettext(
          "Every posting attributed to this organization inherits this standing list, on top of its own. Use it to keep vacancies away from competitors you never advertise to."
        )}
      </p>

      <div class="mt-6">
        <.exclusion_panel
          member_form={@member_form}
          member_error={@member_error}
          org_form={@org_form}
          org_error={@org_error}
          domain_form={@domain_form}
          exclusions={@exclusions}
        />
      </div>
    </div>
    """
  end
end
