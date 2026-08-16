defmodule VutuvWeb.OrganizationLive.Roles do
  @moduledoc """
  The owner-only organization team roster (`/organizations/:slug/roles`, issue #930). Add
  a member by `@handle`/email (with a live typeahead), tick the roles they hold,
  or remove them. The organization always keeps ≥ 1 owner, so removing or
  un-ticking the last owner is refused.

  Since issue #1333 a member may hold **several** roles, so each row is one
  member with a set of checkboxes rather than one role with a select. That is
  not only a wider control: with a select, granting `publisher` to an admin
  would have silently taken their `admin` away, which is the mistake the whole
  role separation exists to prevent.

  Embedded via `live_render` from `VutuvWeb.OrganizationController`, which gates it on
  an owner.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.OrganizationComponents, only: [manage_header: 1, role_label: 1, role_hint: 1]
  import VutuvWeb.UserHelpers, only: [full_name: 1]

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Organizations
  alias VutuvWeb.Live.InitAssigns

  @impl true
  def mount(_params, session, socket) do
    socket = InitAssigns.assign_embedded(socket, session)
    organization = Organizations.get_organization!(session["organization_id"])

    {:ok,
     socket
     |> assign(:organization, organization)
     |> assign(:page_title, gettext("Team – %{name}", name: organization.name))
     |> assign(:identifier, "")
     # Nothing pre-ticked: with four roles a guessed default is wrong more often
     # than right, and `publisher` in particular must never arrive by accident.
     |> assign(:add_roles, [])
     |> assign(:roles_options, Organizations.roles())
     |> assign(:suggestions, [])
     |> load_team()}
  end

  defp load_team(socket) do
    assign(socket, :team, Organizations.list_team(socket.assigns.organization))
  end

  @impl true
  def handle_event("suggest", %{"identifier" => term} = params, socket) do
    exclude = Enum.map(socket.assigns.team, & &1.user.id)

    {:noreply,
     socket
     |> assign(:identifier, term)
     |> assign(:add_roles, checked_roles(params))
     |> assign(:suggestions, Organizations.suggest_members(term, exclude))}
  end

  def handle_event("pick", %{"username" => username}, socket) do
    {:noreply, socket |> assign(:identifier, "@" <> username) |> assign(:suggestions, [])}
  end

  def handle_event("add_member", %{"identifier" => identifier} = params, socket) do
    roles = checked_roles(params)
    organization = socket.assigns.organization

    case identifier |> String.trim() |> Accounts.get_user_by_handle_or_email() do
      %User{} = user when roles != [] ->
        add_and_flash(socket, organization, user, roles)

      %User{} ->
        {:noreply, put_flash(socket, :error, gettext("Pick at least one role."))}

      nil ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("No member found for “%{id}”.", id: String.trim(identifier))
         )}
    end
  end

  def handle_event("set_roles", %{"user_id" => user_id} = params, socket) do
    with_team_member(socket, user_id, fn user ->
      apply_roles(socket, user, checked_roles(params), gettext("Roles updated."))
    end)
  end

  def handle_event("remove", %{"user_id" => user_id}, socket) do
    with_team_member(socket, user_id, fn user ->
      apply_roles(socket, user, [], gettext("Member removed."))
    end)
  end

  # Resolves a roster row by member id. Scoping the lookup to the team the
  # socket already holds is the authorization: an id that is not on this
  # organization's roster simply does not resolve, so a forged `user_id` cannot
  # reach `set_roles/4` for someone else's page.
  defp with_team_member(socket, user_id, fun) do
    case Enum.find(socket.assigns.team, &(&1.user.id == user_id)) do
      nil -> {:noreply, socket}
      entry -> fun.(entry.user)
    end
  end

  defp apply_roles(socket, user, roles, message) do
    case Organizations.set_roles(
           socket.assigns.organization,
           user,
           roles,
           socket.assigns.current_user
         ) do
      {:ok, _roles} ->
        {:noreply, socket |> load_team() |> put_flash(:info, message)}

      {:error, :last_owner} ->
        {:noreply, socket |> load_team() |> put_flash(:error, last_owner_error())}
    end
  end

  # The checkbox group posts one param per ticked role (`roles[publisher]="true"`),
  # and nothing at all when every box is cleared, so a missing `"roles"` key means
  # "none" rather than "unchanged".
  defp checked_roles(params) do
    params
    |> Map.get("roles", %{})
    |> Enum.filter(fn {_role, value} -> value in ["true", "on"] end)
    |> Enum.map(fn {role, _} -> role end)
    |> Organizations.rank_roles()
  end

  defp add_and_flash(socket, organization, user, roles) do
    case Organizations.set_roles(organization, user, roles, socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:identifier, "")
         |> assign(:suggestions, [])
         |> load_team()
         |> put_flash(:info, gettext("Added @%{handle} to the team.", handle: user.username))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("That member could not be added."))}
    end
  end

  defp last_owner_error,
    do:
      gettext(
        "An organization must keep at least one owner, so the last owner cannot be changed."
      )

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl py-6">
      <.manage_header
        organization={@organization}
        active={:roles}
        viewer={@current_user}
      />

      <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">{gettext("Team")}</h1>
      <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
        {gettext("Give members their roles on this page. Someone can hold several at once, and every role is granted on its own.")}
      </p>

      <.card class="mt-6">
        <.section_title>{gettext("Add a member")}</.section_title>
        <.form for={%{}} id="add-member-form" phx-submit="add_member" phx-change="suggest" class="mt-3 space-y-3">
          <div class="relative">
            <input
              type="text"
              name="identifier"
              value={@identifier}
              autocomplete="off"
              phx-debounce="200"
              placeholder={gettext("@handle or email")}
              class={input_class()}
            />
            <ul
              :if={@suggestions != []}
              class="absolute z-10 mt-1 w-full overflow-hidden rounded-lg border border-slate-200 bg-white shadow-lg dark:border-slate-700 dark:bg-slate-800"
            >
              <li :for={user <- @suggestions}>
                <button
                  type="button"
                  phx-click="pick"
                  phx-value-username={user.username}
                  class="flex w-full items-center gap-2 px-3 py-2 text-left text-sm hover:bg-slate-50 dark:hover:bg-slate-700"
                >
                  <.avatar user={user} size="xs" shape="circle" />
                  <span class="min-w-0">
                    <span class="block truncate font-medium text-slate-900 dark:text-slate-100">{full_name(user)}</span>
                    <span class="block truncate text-xs text-slate-600 dark:text-slate-400">@{user.username}</span>
                  </span>
                </button>
              </li>
            </ul>
          </div>

          <.role_checkboxes id="add" options={@roles_options} checked={@add_roles} hints={true} />

          <button
            type="submit"
            class="rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white hover:bg-brand-700"
          >
            {gettext("Add")}
          </button>
        </.form>
      </.card>

      <.card class="mt-6">
        <.section_title>{gettext("Current team")}</.section_title>
        <ul class="mt-3 divide-y divide-slate-100 dark:divide-slate-800">
          <li :for={entry <- @team} id={"member-#{entry.user.id}"} class="py-4">
            <div class="flex items-center gap-3">
              <.avatar user={entry.user} size="sm" shape="circle" />
              <div class="min-w-0 flex-1">
                <.link
                  navigate={"/#{entry.user.username}"}
                  class="block truncate font-medium text-slate-900 hover:text-brand-700 dark:text-slate-100"
                >
                  {full_name(entry.user)}
                </.link>
                <span class="block truncate text-xs text-slate-600 dark:text-slate-400">@{entry.user.username}</span>
              </div>

              <button
                type="button"
                phx-click="remove"
                phx-value-user_id={entry.user.id}
                data-confirm={
                  if(entry.user.id == @current_user_id,
                    do: gettext("Leave this organization team?"),
                    else: gettext("Remove this member from the team?")
                  )
                }
                class="shrink-0 text-sm font-semibold text-red-600 hover:text-red-700"
              >
                {if entry.user.id == @current_user_id, do: gettext("Leave"), else: gettext("Remove")}
              </button>
            </div>

            <form phx-change="set_roles" class="mt-2">
              <input type="hidden" name="user_id" value={entry.user.id} />
              <.role_checkboxes id={"member-#{entry.user.id}"} options={@roles_options} checked={entry.roles} />
            </form>
          </li>
        </ul>
      </.card>
    </div>
    """
  end

  # One checkbox per role. Each box carries a matching hidden "false" field so a
  # box the owner CLEARS still reaches the server as a value — without it the
  # browser simply omits it, and un-ticking the last box would send no `roles`
  # key at all on a form whose other fields are unchanged.
  attr(:id, :string, required: true)
  attr(:options, :list, required: true)
  attr(:checked, :list, required: true)
  attr(:hints, :boolean, default: false)

  defp role_checkboxes(assigns) do
    ~H"""
    <fieldset class="flex flex-wrap gap-x-5 gap-y-2">
      <legend class="sr-only">{gettext("Roles")}</legend>
      <label :for={role <- @options} for={"#{@id}-role-#{role}"} class="flex min-h-10 items-start gap-2">
        <input type="hidden" name={"roles[#{role}]"} value="false" />
        <input
          type="checkbox"
          id={"#{@id}-role-#{role}"}
          name={"roles[#{role}]"}
          value="true"
          checked={role in @checked}
          data-role-checkbox={role}
          class={checkbox_class()}
        />
        <span class="min-w-0">
          <span class="block text-sm font-medium text-slate-900 dark:text-slate-100">{role_label(role)}</span>
          <span :if={@hints} class="block text-xs text-slate-600 dark:text-slate-400">{role_hint(role)}</span>
        </span>
      </label>
    </fieldset>
    """
  end
end
