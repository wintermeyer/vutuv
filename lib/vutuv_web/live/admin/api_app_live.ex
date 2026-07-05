defmodule VutuvWeb.Admin.ApiAppLive do
  @moduledoc """
  The operator's view of every registered OAuth application, with the bad-player
  kill switch (`/admin/api_apps`). Suspending an app makes all of its tokens fail
  on their very next request (`Vutuv.ApiAuth.verify_token/1` checks `suspended_at`
  live); unsuspending restores them. Both toggles act **reload-free** over the
  socket; the classic CSRF POSTs (`ApiAppController.suspend/unsuspend`) stay as the
  no-JS / scriptable fallback. Lives in the `:admin` live_session.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.UserHelpers, only: [full_name: 1]

  alias Vutuv.ApiAuth

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("API applications"))
     |> assign(:apps, ApiAuth.list_all_apps())}
  end

  @impl true
  def handle_event("suspend", %{"id" => id}, socket) do
    toggle(socket, id, &ApiAuth.suspend_app!/1, fn app ->
      gettext("\"%{name}\" is suspended; its tokens are refused.", name: app.name)
    end)
  end

  def handle_event("unsuspend", %{"id" => id}, socket) do
    toggle(socket, id, &ApiAuth.unsuspend_app!/1, fn app ->
      gettext("\"%{name}\" is active again.", name: app.name)
    end)
  end

  defp toggle(socket, id, action, message) do
    case ApiAuth.get_any_app(id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("That application no longer exists."))}

      app ->
        action.(app)

        {:noreply,
         socket
         |> put_flash(:info, message.(app))
         |> assign(:apps, ApiAuth.list_all_apps())}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title={gettext("API applications")}
      crumbs={[{gettext("Admin"), ~p"/admin"}, gettext("API applications")]}
    />

    <div class="card-list">
      <section class="card">
        <p :if={@apps == []} class="card__empty">
          {gettext("No application has been registered yet.")}
        </p>

        <div :if={@apps != []} class="card__tablewrap">
          <table class="pure-table">
            <thead>
              <tr>
                <th>{gettext("Name")}</th>
                <th>{gettext("Owner")}</th>
                <th>{gettext("Registered")}</th>
                <th>{gettext("Status")}</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={app <- @apps} id={"api-app-#{app.id}"}>
                <td>{app.name}</td>
                <td>
                  <.link href={~p"/#{app.user}"} class="text-brand-600 hover:text-brand-700">
                    @{app.user.username}
                  </.link>
                  <span class="text-slate-600 dark:text-slate-400">({full_name(app.user)})</span>
                </td>
                <td>
                  <.local_time at={app.inserted_at} id={"api-app-time-#{app.id}"} format="%Y-%m-%d" />
                </td>
                <td>
                  <span :if={app.suspended_at} class="font-semibold text-red-600">
                    {gettext("Suspended")}
                  </span>
                  <span :if={is_nil(app.suspended_at)}>{gettext("Active")}</span>
                </td>
                <td class="text-right">
                  <button
                    :if={app.suspended_at}
                    type="button"
                    class="button button--secondary button--small"
                    id={"unsuspend-#{app.id}"}
                    phx-click="unsuspend"
                    phx-value-id={app.id}
                  >
                    {gettext("Reactivate")}
                  </button>
                  <button
                    :if={is_nil(app.suspended_at)}
                    type="button"
                    class="button button--danger button--small"
                    id={"suspend-#{app.id}"}
                    phx-click="suspend"
                    phx-value-id={app.id}
                    data-confirm={
                      gettext("Suspend \"%{name}\"? All of its tokens stop working immediately.",
                        name: app.name
                      )
                    }
                  >
                    {gettext("Suspend")}
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </div>
    """
  end
end
