defmodule VutuvWeb.OrganizationLive.Roles do
  @moduledoc """
  The owner-only organization team roster (`/organizations/:slug/roles`, issue #930). Add
  a member by `@handle`/email (with a live typeahead), pick their role
  (owner / admin / recruiter), change a role, or remove someone. The organization
  always keeps ≥ 1 owner, so removing or demoting the last owner is refused.
  Embedded via `live_render` from `VutuvWeb.OrganizationController`, which gates it on
  an owner.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.OrganizationComponents, only: [manage_header: 1, role_label: 1]
  import VutuvWeb.UserHelpers, only: [full_name: 1]

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Organizations
  alias VutuvWeb.Live.InitAssigns

  @roles ~w(owner admin recruiter)

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
     |> assign(:page_title, gettext("Team – %{name}", name: organization.name))
     |> assign(:identifier, "")
     |> assign(:add_role, "recruiter")
     |> assign(:roles_options, @roles)
     |> assign(:suggestions, [])
     |> load_roles()}
  end

  defp load_roles(socket) do
    assign(socket, :roles, Organizations.list_roles(socket.assigns.organization))
  end

  @impl true
  def handle_event("suggest", %{"identifier" => term} = params, socket) do
    exclude = Enum.map(socket.assigns.roles, & &1.user_id)
    role = params["role"] || socket.assigns.add_role

    {:noreply,
     socket
     |> assign(:identifier, term)
     |> assign(:add_role, role)
     |> assign(:suggestions, Organizations.suggest_members(term, exclude))}
  end

  def handle_event("pick", %{"username" => username}, socket) do
    {:noreply, socket |> assign(:identifier, "@" <> username) |> assign(:suggestions, [])}
  end

  def handle_event("add_member", %{"identifier" => identifier} = params, socket) do
    role = params["role"] || socket.assigns.add_role
    organization = socket.assigns.organization

    case identifier |> String.trim() |> Accounts.get_user_by_handle_or_email() do
      %User{} = user ->
        add_and_flash(socket, organization, user, role)

      nil ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("No member found for “%{id}”.", id: String.trim(identifier))
         )}
    end
  end

  def handle_event("change_role", %{"role_id" => role_id, "role" => role}, socket)
      when role in @roles do
    case Organizations.get_role(socket.assigns.organization, role_id) do
      nil ->
        {:noreply, socket}

      role_row ->
        socket.assigns.current_user
        |> then(&Organizations.update_role(role_row, role, &1))
        |> case do
          {:ok, _} ->
            {:noreply, socket |> load_roles() |> put_flash(:info, gettext("Role updated."))}

          {:error, :last_owner} ->
            {:noreply, put_flash(socket, :error, last_owner_error())}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("That change could not be saved."))}
        end
    end
  end

  def handle_event("remove", %{"id" => role_id}, socket) do
    case Organizations.get_role(socket.assigns.organization, role_id) do
      nil ->
        {:noreply, socket}

      role_row ->
        case Organizations.remove_role(role_row) do
          {:ok, _} ->
            {:noreply, socket |> load_roles() |> put_flash(:info, gettext("Member removed."))}

          {:error, :last_owner} ->
            {:noreply, put_flash(socket, :error, last_owner_error())}
        end
    end
  end

  defp add_and_flash(socket, organization, user, role) do
    case Organizations.add_role(organization, user, role, socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:identifier, "")
         |> assign(:suggestions, [])
         |> load_roles()
         |> put_flash(:info, gettext("Added @%{handle} to the team.", handle: user.username))}

      {:error, :already_member} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("@%{handle} is already on the team.", handle: user.username)
         )}

      {:error, _changeset} ->
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
      <.manage_header organization={@organization} active={:roles} owner?={true} />

      <h1 class="text-2xl font-bold text-slate-900 dark:text-slate-100">{gettext("Team")}</h1>
      <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
        {gettext("Give members a role on this page. Owners manage the team and domains, admins edit the page, recruiters post jobs.")}
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

          <div class="flex flex-wrap items-center gap-3">
            <select name="role" class={[input_class(), "w-auto"]}>
              <option :for={role <- @roles_options} value={role} selected={role == @add_role}>
                {role_label(role)}
              </option>
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

      <.card class="mt-6">
        <.section_title>{gettext("Current team")}</.section_title>
        <ul class="mt-3 divide-y divide-slate-100 dark:divide-slate-800">
          <li :for={role <- @roles} id={"role-#{role.id}"} class="flex items-center gap-3 py-3">
            <.avatar user={role.user} size="sm" shape="circle" />
            <div class="min-w-0 flex-1">
              <.link
                navigate={"/#{role.user.username}"}
                class="block truncate font-medium text-slate-900 hover:text-brand-700 dark:text-slate-100"
              >
                {full_name(role.user)}
              </.link>
              <span class="block truncate text-xs text-slate-600 dark:text-slate-400">@{role.user.username}</span>
            </div>

            <form phx-change="change_role" class="shrink-0">
              <input type="hidden" name="role_id" value={role.id} />
              <select name="role" class={[input_class(), "w-auto py-1.5 text-xs"]}>
                <option :for={r <- @roles_options} value={r} selected={r == role.role}>{role_label(r)}</option>
              </select>
            </form>

            <button
              type="button"
              phx-click="remove"
              phx-value-id={role.id}
              data-confirm={
                if(role.user_id == @current_user_id,
                  do: gettext("Leave this organization team?"),
                  else: gettext("Remove this member from the team?")
                )
              }
              class="shrink-0 text-sm font-semibold text-red-600 hover:text-red-700"
            >
              {if role.user_id == @current_user_id, do: gettext("Leave"), else: gettext("Remove")}
            </button>
          </li>
        </ul>
      </.card>
    </div>
    """
  end
end
