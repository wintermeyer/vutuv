defmodule VutuvWeb.JobPostingLive.Exclusions do
  @moduledoc """
  The per-posting exclusion editor (`/jobs/:slug/exclusions`, issue #939),
  owner-only. Hide a posting from specific members, whole organizations
  (competitors, your own employer) or email domains — subtracted as the last step
  of the posting's visibility gate, so it only ever narrows who sees it, never
  widens it. An org-attributed posting also inherits its organization's standing
  default (managed on the organization's own exclusions page), shown read-only
  here.

  A LiveView so rows add and remove with no reload; it drives the shared
  `VutuvWeb.JobExclusionComponents.exclusion_panel/1` and owns the four events it
  emits.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.JobExclusionComponents

  alias Vutuv.Jobs
  alias Vutuv.Jobs.Exclusions

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    posting = Jobs.get_job_posting_by_slug(slug)

    cond do
      is_nil(socket.assigns.current_user) ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Please log in first."))
         |> push_navigate(to: ~p"/login")}

      posting && Jobs.owner?(posting, socket.assigns.current_user) ->
        {:ok,
         socket
         |> assign(:page_title, gettext("Hide from specific viewers"))
         |> assign(:posting, posting)
         |> assign(:organization, posting.organization)
         |> assign(:member_error, nil)
         |> assign(:org_error, nil)
         |> assign_member_form()
         |> assign_org_form()
         |> assign_domain_form()
         |> load_exclusions()}

      true ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Posting not found."))
         |> push_navigate(to: ~p"/jobs/mine")}
    end
  end

  @impl true
  def handle_event("add_member", %{"member" => %{"handle" => handle}}, socket) do
    case Exclusions.add_posting_member(socket.assigns.posting, handle) do
      {:ok, _} ->
        {:noreply,
         socket |> assign(:member_error, nil) |> assign_member_form() |> load_exclusions()}

      {:error, reason} ->
        {:noreply, assign(socket, :member_error, member_error_message(reason))}
    end
  end

  def handle_event("add_organization", %{"organization" => %{"handle" => handle}}, socket) do
    case Exclusions.add_posting_organization(socket.assigns.posting, handle) do
      {:ok, _} ->
        {:noreply, socket |> assign(:org_error, nil) |> assign_org_form() |> load_exclusions()}

      {:error, reason} ->
        {:noreply, assign(socket, :org_error, org_error_message(reason))}
    end
  end

  def handle_event("add_domain", %{"domain" => params}, socket) do
    case Exclusions.add_posting_domain(socket.assigns.posting, params) do
      {:ok, _} ->
        {:noreply, socket |> assign_domain_form() |> load_exclusions()}

      {:error, changeset} ->
        {:noreply, assign(socket, :domain_form, to_form(changeset, as: :domain))}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    :ok = Exclusions.remove_from_posting(socket.assigns.posting, id)
    {:noreply, load_exclusions(socket)}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_exclusions(socket) do
    posting = socket.assigns.posting

    socket
    |> assign(:exclusions, Exclusions.list_for_posting(posting))
    |> assign(:inherited, inherited_defaults(socket.assigns.organization))
  end

  defp inherited_defaults(nil), do: []
  defp inherited_defaults(organization), do: Exclusions.list_for_organization(organization)

  defp assign_member_form(socket),
    do: assign(socket, :member_form, to_form(%{"handle" => ""}, as: :member))

  defp assign_org_form(socket),
    do: assign(socket, :org_form, to_form(%{"handle" => ""}, as: :organization))

  defp assign_domain_form(socket) do
    changeset = Exclusions.change_posting_domain(socket.assigns.posting)
    assign(socket, :domain_form, to_form(changeset, as: :domain))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="mx-auto max-w-2xl px-4 py-6">
      <.link
        navigate={~p"/jobs/#{@posting.slug}/edit"}
        class="text-sm font-semibold text-slate-600 hover:text-slate-800 dark:text-slate-400 dark:hover:text-slate-200"
      >
        ← {gettext("Back to the posting")}
      </.link>

      <h1 class="mt-3 text-2xl font-bold text-slate-900 dark:text-slate-100">
        {gettext("Hide from specific viewers")}
      </h1>
      <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
        {gettext("“%{title}”", title: @posting.title)}
      </p>

      <.card class="mt-4">
        <p class="text-sm text-slate-600 dark:text-slate-400">
          {gettext(
            "People and organizations on this list never see this posting: it drops off their board, their search, its detail page and their job alerts, with no hint they were singled out."
          )}
        </p>
        <p :if={@posting.visibility == :everyone} class="mt-2 text-sm text-slate-600 dark:text-slate-400">
          {gettext(
            "This posting is public, so excluding only narrows the signed-in audience: someone can still read it while logged out. To also hide it from logged-out visitors, set its visibility to “Members only”."
          )}
        </p>
      </.card>

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

      <.card :if={@inherited != []} class="mt-6">
        <.section_title>{gettext("Inherited from the organization")}</.section_title>
        <p class="mt-2 text-sm text-slate-600 dark:text-slate-400">
          {gettext(
            "This posting also inherits %{count} standing exclusion(s) from %{name}, managed on its exclusions page.",
            count: length(@inherited),
            name: @organization.name
          )}
        </p>
        <.link
          :if={@organization}
          navigate={~p"/organizations/#{@organization.slug}/exclusions"}
          class="mt-2 inline-block text-sm font-semibold text-brand-600 hover:text-brand-700"
        >
          {gettext("Manage the organization's default list")} →
        </.link>
      </.card>
    </main>
    """
  end
end
