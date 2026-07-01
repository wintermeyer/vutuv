defmodule VutuvWeb.Admin.UserDeleteLive do
  @moduledoc """
  The admin "delete account" page (`/admin/users/delete`): search for a member
  the way the site search does (by name, @handle or email), then delete the
  account behind an "Are you sure?" confirmation modal.

  Deleting goes through `Vutuv.Accounts.admin_delete_user/1`, which removes the
  account **and everything it owns** (posts, phone numbers, email addresses,
  tags, endorsements, images, follows) via the `delete_user/1` cascade, sends
  the member **no** email, and mails the operator a record of what was deleted
  with the exact timestamp.

  Lives in the `:admin` live_session (`on_mount :require_admin`, see the router)
  so the dead `:admin` pipeline 403s the disconnected render and the on_mount
  guards the socket. Search-as-you-type only, no URL state: a destructive tool
  is not something anyone wants to bookmark or share.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.UserHelpers, only: [full_name: 1]

  alias Vutuv.Accounts

  # Most matches shown for a query. An admin who needs a specific account
  # narrows the search rather than scrolling; a destructive list stays short.
  @results_limit 25

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Delete account"))
     |> assign(:query, "")
     |> assign(:results, [])
     |> assign(:confirming, nil)}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply,
     socket
     |> assign(:query, q)
     |> assign(:results, search_users(q))}
  end

  # Open the confirmation modal for the row the admin clicked. The listing row
  # carries enough to name the account in the modal; the full row is reloaded
  # at delete time.
  def handle_event("confirm", %{"id" => id}, socket) do
    {:noreply, assign(socket, :confirming, Enum.find(socket.assigns.results, &(&1.id == id)))}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, :confirming, nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    socket =
      socket
      |> assign(:confirming, nil)
      |> assign(:results, Enum.reject(socket.assigns.results, &(&1.id == id)))

    # Reload the full row: the search result is a sparse listing struct, but
    # delete_user/1 needs the whole account (e.g. the cover-photo path) to purge
    # its on-disk files.
    case Accounts.get_user(id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("That account no longer exists."))}

      user ->
        {:ok, _} = Accounts.admin_delete_user(user)

        {:noreply,
         put_flash(
           socket,
           :info,
           gettext(
             "Account @%{username} was deleted. A record was emailed to the operator.",
             username: user.username
           )
         )}
    end
  end

  defp search_users(q) do
    filters = Accounts.admin_user_filters(%{"q" => q, "reg" => "all", "flag" => "all"})

    if filters.q do
      Accounts.list_admin_users(filters, %{"page" => 1}, per_page: @results_limit)
    else
      []
    end
  end

  # A blank query is the "start here" state, distinct from "searched, no hits".
  defp searched?(query), do: String.trim(to_string(query)) != ""

  defp member_name(user) do
    case String.trim(full_name(user)) do
      "" -> "@" <> (user.username || "")
      name -> name
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title={gettext("Delete account")}
      crumbs={[{gettext("Admin"), ~p"/admin"}, gettext("Delete account")]}
    />

    <div class="card-list">
      <section class="card">
        <h1>{gettext("Delete account")}</h1>
        <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
          {gettext(
            "Find a member by name, @handle or email, then delete the account. Deletion is permanent: it removes the account and everything it owns (posts, phone numbers, email addresses, tags and more). The member is not emailed; a record is sent to the operator."
          )}
        </p>

        <form id="user-search" phx-change="search" phx-submit="search" class="mt-4">
          <label for="search-q" class="block text-sm font-semibold text-slate-700 dark:text-slate-200">
            {gettext("Search")}
          </label>
          <input
            type="search"
            name="q"
            id="search-q"
            value={@query}
            phx-debounce="250"
            autocomplete="off"
            placeholder={gettext("name, @handle or email")}
            class={input_class()}
          />
        </form>

        <p :if={not searched?(@query)} class="card__empty">
          {gettext("Type a name, @handle or email to find the account to delete.")}
        </p>
        <p :if={searched?(@query) and @results == []} class="card__empty">
          {gettext("No accounts match your search.")}
        </p>

        <div :if={@results != []} class="mt-4 card__tablewrap">
          <table class="pure-table">
            <thead>
              <tr>
                <th>{gettext("Member")}</th>
                <th>{gettext("Username")}</th>
                <th>{gettext("Joined")}</th>
                <th></th>
              </tr>
            </thead>
            <tbody id="delete-results">
              <tr :for={user <- @results} id={"user-#{user.id}"}>
                <td>
                  <.link navigate={~p"/#{user}"} class="flex items-center gap-2">
                    <.avatar user={user} size="xs" />
                    <span class="breakwrap font-medium">{member_name(user)}</span>
                  </.link>
                </td>
                <td class="breakwrap">
                  <.link navigate={~p"/#{user}"} class="text-brand-600 hover:text-brand-700">
                    @{user.username}
                  </.link>
                </td>
                <td class="whitespace-nowrap text-slate-600 dark:text-slate-400">
                  <.local_time at={user.inserted_at} id={"joined-#{user.id}"} format="%Y-%m-%d" />
                </td>
                <td class="text-right">
                  <button
                    type="button"
                    phx-click="confirm"
                    phx-value-id={user.id}
                    class="rounded-lg bg-rose-600 px-3 py-1 text-xs font-semibold text-white hover:bg-rose-700"
                  >
                    {gettext("Delete")}
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </div>

    <div
      :if={@confirming}
      id="delete-modal"
      class="fixed inset-0 z-50 flex items-center justify-center p-4"
      role="dialog"
      aria-modal="true"
      aria-labelledby="delete-modal-title"
      phx-window-keydown="cancel"
      phx-key="Escape"
    >
      <div class="fixed inset-0 bg-slate-900/50" phx-click="cancel" aria-hidden="true"></div>
      <div class="relative z-10 w-full max-w-md rounded-2xl bg-white p-6 shadow-xl ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800">
        <h2 id="delete-modal-title" class="text-lg font-semibold text-slate-900 dark:text-slate-100">
          {gettext("Delete this account?")}
        </h2>
        <p class="mt-2 text-sm text-slate-600 dark:text-slate-400">
          {gettext(
            "This permanently deletes the account and everything it owns (posts, phone numbers, email addresses, tags and more). This cannot be undone. The member is not notified; a record is emailed to the operator."
          )}
        </p>
        <div class="mt-4 rounded-lg bg-slate-50 p-3 text-sm dark:bg-slate-800">
          <p class="font-medium text-slate-900 dark:text-slate-100">{member_name(@confirming)}</p>
          <p class="text-slate-600 dark:text-slate-400">{"@" <> @confirming.username}</p>
        </div>
        <div class="mt-6 flex justify-end gap-3">
          <button
            type="button"
            phx-click="cancel"
            class="rounded-lg bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-200 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
          >
            {gettext("Cancel")}
          </button>
          <button
            type="button"
            id="confirm-delete"
            phx-click="delete"
            phx-value-id={@confirming.id}
            class="rounded-lg bg-rose-600 px-4 py-2 text-sm font-semibold text-white hover:bg-rose-700"
          >
            {gettext("Delete account")}
          </button>
        </div>
      </div>
    </div>
    """
  end
end
