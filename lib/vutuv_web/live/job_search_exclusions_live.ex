defmodule VutuvWeb.JobSearchExclusionsLive do
  @moduledoc """
  The job-search viewer-exclusion editor (GET /settings/job_search_exclusions,
  issue #938): the "hide from your employer" escape hatch #928 deferred. A
  member adds specific members (by @handle) or email domains that never see
  their availability badge or salary expectation, even at "Everyone" — the
  list is subtracted as the last step of the visibility gate
  (`Vutuv.Accounts.viewer_excluded?/2`), so it only ever narrows the
  audience, never widens it.

  A LiveView so rows add and remove with no reload, and each change broadcasts
  `{:job_search_visibility_changed, _}` on the owner's `Vutuv.Activity` topic
  so an open profile (an excluded member watching) drops the badge live too.
  Its own page rather than inline in the basics form, because add/remove forms
  cannot nest inside that form; the basics-form Jobsuche panel links here.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.ErrorHelpers

  on_mount({VutuvWeb.Live.InitAssigns, :require_login})

  alias Vutuv.Accounts
  alias Vutuv.Accounts.ViewerExclusion
  alias Vutuv.Activity
  alias VutuvWeb.UserHelpers

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Job-search exclusion list"))
     |> assign(:user, socket.assigns.current_user)
     |> assign(:member_error, nil)
     |> assign_member_form()
     |> assign_domain_form()
     |> load_exclusions()}
  end

  @impl true
  def handle_event("add_member", %{"member" => %{"handle" => handle}}, socket) do
    case Accounts.add_excluded_member(socket.assigns.user, handle) do
      {:ok, _exclusion} ->
        {:noreply,
         socket
         |> assign(:member_error, nil)
         |> assign_member_form()
         |> load_exclusions()
         |> broadcast_change()}

      {:error, reason} ->
        {:noreply, assign(socket, :member_error, member_error_message(reason))}
    end
  end

  def handle_event("add_domain", %{"domain" => params}, socket) do
    case Accounts.add_excluded_domain(socket.assigns.user, params) do
      {:ok, _exclusion} ->
        {:noreply,
         socket
         |> assign_domain_form()
         |> load_exclusions()
         |> broadcast_change()}

      {:error, changeset} ->
        {:noreply, assign(socket, :domain_form, to_form(changeset, as: :domain))}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    :ok = Accounts.remove_viewer_exclusion(socket.assigns.user, id)

    {:noreply,
     socket
     |> load_exclusions()
     |> broadcast_change()}
  end

  defp load_exclusions(socket) do
    assign(socket, :exclusions, Accounts.list_viewer_exclusions(socket.assigns.user))
  end

  defp assign_member_form(socket) do
    assign(socket, :member_form, to_form(%{"handle" => ""}, as: :member))
  end

  defp assign_domain_form(socket) do
    changeset = ViewerExclusion.domain_changeset(socket.assigns.user, %{})
    assign(socket, :domain_form, to_form(changeset, as: :domain))
  end

  # Re-render any open profile of this member: an excluded viewer's badge /
  # salary line drops out (or reappears) with no reload.
  defp broadcast_change(socket) do
    Activity.broadcast(socket.assigns.user.id, {:job_search_visibility_changed, %{}})
    socket
  end

  defp member_error_message(:not_found), do: gettext("No member has that @handle.")
  defp member_error_message(:self), do: gettext("You cannot exclude yourself.")
  defp member_error_message(:duplicate), do: gettext("That member is already on your list.")

  defp member_error_message(:full),
    do:
      gettext("Your exclusion list is full (max %{count}).",
        count: Accounts.viewer_exclusion_cap()
      )

  @impl true
  def render(assigns) do
    ~H"""
    <.settings_shell user={@user} active={:basics} title={gettext("Job-search exclusion list")}>
      <div class="space-y-6">
        <.card>
          <p class="text-sm text-slate-600 dark:text-slate-400">
            {gettext(
              "People and email domains on this list never see that you are open to work, or your salary expectation, even when your availability is set to \"Everyone\". Excluding reduces who can see it but cannot guarantee it: someone can still look while logged out, or from a private email address."
            )}
          </p>
        </.card>

        <.card>
          <.section_title>{gettext("Exclude a member")}</.section_title>
          <.form
            for={@member_form}
            id="exclude-member-form"
            phx-submit="add_member"
            class="mt-3 flex flex-wrap items-start gap-2"
          >
            <div class="min-w-0 flex-1">
              <input
                type="text"
                name="member[handle]"
                value={@member_form[:handle].value}
                placeholder="@username"
                autocomplete="off"
                aria-label={gettext("Member @handle")}
                aria-invalid={@member_error && "true"}
                class={input_class(!!@member_error)}
              />
              <p :if={@member_error} class="editform__error mt-1" id="member-error">{@member_error}</p>
            </div>
            <.button type="submit">{gettext("Exclude")}</.button>
          </.form>
        </.card>

        <.card>
          <.section_title>{gettext("Exclude an email domain")}</.section_title>
          <.form
            for={@domain_form}
            id="exclude-domain-form"
            phx-submit="add_domain"
            class="mt-3 flex flex-wrap items-start gap-2"
          >
            <div class="min-w-0 flex-1">
              <input
                type="text"
                name="domain[domain]"
                value={@domain_form[:domain].value}
                placeholder="example.com"
                autocomplete="off"
                aria-label={gettext("Email domain")}
                aria-invalid={@domain_form[:domain].errors != [] && "true"}
                class={input_class(@domain_form, :domain)}
              />
              {error_tag(@domain_form, :domain)}
            </div>
            <.button type="submit">{gettext("Exclude")}</.button>
          </.form>
          <p class="mt-2 text-sm text-slate-600 dark:text-slate-400">
            {gettext(
              "Any signed-in member whose confirmed email is at this domain, or a subdomain of it, is excluded. This is the reliable way to hide from your whole organization."
            )}
          </p>
        </.card>

        <.card>
          <.section_title>
            {gettext("Currently excluded")} ({compact_count(length(@exclusions))})
          </.section_title>

          <p :if={@exclusions == []} class="mt-3 text-sm text-slate-600 dark:text-slate-400">
            {gettext("Your list is empty. Nobody is excluded yet.")}
          </p>

          <ul
            :if={@exclusions != []}
            id="exclusion-list"
            class="mt-3 divide-y divide-slate-100 dark:divide-slate-800"
          >
            <li
              :for={x <- @exclusions}
              id={"exclusion-#{x.id}"}
              class="flex items-center justify-between gap-3 py-3"
            >
              <div class="flex min-w-0 items-center gap-3">
                <%= if x.excluded_user do %>
                  <.avatar user={x.excluded_user} size="xs" shape="circle" />
                  <div class="min-w-0">
                    <.link
                      navigate={~p"/#{x.excluded_user}"}
                      class="block truncate font-medium text-slate-900 hover:text-brand-700 dark:text-white dark:hover:text-brand-300"
                    >
                      {UserHelpers.full_name(x.excluded_user)}
                    </.link>
                    <span class="block truncate text-sm text-slate-600 dark:text-slate-400">
                      @{x.excluded_user.username}
                    </span>
                  </div>
                <% else %>
                  <span
                    aria-hidden="true"
                    class="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-slate-100 text-slate-500 dark:bg-slate-800 dark:text-slate-400"
                  >
                    @
                  </span>
                  <div class="min-w-0">
                    <span class="block truncate font-medium text-slate-900 dark:text-white">
                      {x.domain}
                    </span>
                    <span class="block text-sm text-slate-600 dark:text-slate-400">
                      {gettext("Email domain")}
                    </span>
                  </div>
                <% end %>
              </div>
              <button
                type="button"
                phx-click="remove"
                phx-value-id={x.id}
                class="shrink-0 text-sm font-semibold text-red-600 hover:text-red-700 dark:text-red-400 dark:hover:text-red-300"
              >
                {gettext("Remove")}
              </button>
            </li>
          </ul>
        </.card>
      </div>
    </.settings_shell>
    """
  end
end
